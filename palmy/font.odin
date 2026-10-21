package palmy

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
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

	// The bidi and shaping scratch, shared by every text procedure. One per
	// `Fonts` is the right number: text measurement runs several times per
	// frame per node, and after the first few lines these buffers stop
	// allocating entirely. The slices they hand out are only valid until the
	// next text call, which is why nothing in `font.odin` lays out a second
	// line while still reading the first.
	shaper: Text_Shaper,
}

// Metrics describes a font at one size, in pixels.
Metrics :: struct {
	ascent:  f32,
	descent: f32,
	line:    f32,
}

// Candidate font files, most preferred first. Anything installed on a typical
// desktop will match one of these; PALMY_FONT and PALMY_FONT_MONO override.
// The SF and Helvetica/Menlo names last are macOS's own, found only there.
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
	"SFNS",
	"HelveticaNeue",
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
	"SFNSMono",
	"Menlo",
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
	"SFNSItalic",
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
	"SFNSMonoItalic",
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
	if !f.faces[.Sans][.Regular][.Upright].ok {
		pick_any_text_face(f, &f.faces[.Sans][.Regular][.Upright], files)
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
		order := WEIGHT_ORDER
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

// WEIGHT_ORDER is, for each weight, the others to borrow from, nearest first.
//
// It is a package-level table and not a procedure returning the same literal,
// and that is load-bearing: the slice literals in a returned value live in the
// callee's stack frame, so every slice the caller indexed was dangling. It
// never showed on a desktop, where every weight has its own file and the
// table is not consulted; on a system with one sans file (Palmy's
// minimal image ships DejaVuSans alone before the kit pins Geist) the first
// missing weight read freed stack and every application died in fonts_init.
@(private)
WEIGHT_ORDER := [Font_Weight][]Font_Weight {
	.Regular  = {.Medium, .Semibold, .Bold},
	.Medium   = {.Regular, .Semibold, .Bold},
	.Semibold = {.Bold, .Medium, .Regular},
	.Bold     = {.Semibold, .Medium, .Regular},
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

	order := WEIGHT_ORDER
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
//
// A path that does not exist is looked up again by file name under the system
// font directories. Applications pin fonts by the absolute path they have on a
// development machine -- the kit loads Geist out of the parity tree -- and on
// an installed system the same file lives in /usr/share/fonts instead. Without
// this second look every such application silently drops to whatever the scan
// picked, which on a minimal system means a different typeface per window.
load_font :: proc(f: ^Fonts, path: string, fam: Font_Family, wt: Font_Weight, sl := Font_Slant.Upright) -> bool {
	face: Face
	if !face_load_relocated(f, &face, path) {
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
	text_shaper_destroy(f)
}

@(private)
font_dirs :: proc() -> []string {
	home := os.get_env("HOME", context.temp_allocator)
	dirs := make([dynamic]string, context.temp_allocator)
	append(&dirs, "/usr/share/fonts", "/usr/local/share/fonts", "/run/current-system/sw/share/X11/fonts")
	if home != "" {
		append(&dirs, fmt.tprintf("%s/.local/share/fonts", home), fmt.tprintf("%s/.fonts", home))
	}
	when ODIN_OS == .Darwin {
		// Supplemental/ sits under the first and is reached by the walk.
		append(&dirs, "/System/Library/Fonts", "/Library/Fonts")
		if home != "" {
			append(&dirs, fmt.tprintf("%s/Library/Fonts", home))
		}
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

// pick_any_text_face is the last resort when no candidate family is
// installed: any upright, regular-looking text face beats the built-in
// segment font. A minimal system ships a font or two that need not be on any
// list -- Adwaita Sans, IBM Plex, whatever the integrator chose -- and without
// this the whole interface fell to the stb_easy_font fallback while a perfectly
// good TrueType file sat in /usr/share/fonts. Files whose names say they are
// not a body face (mono, emoji, symbols, a script-specific Noto) are passed
// over, and the walk order makes the choice stable across runs.
@(private)
pick_any_text_face :: proc(f: ^Fonts, face: ^Face, files: [dynamic]string) {
	SKIP :: [?]string{"mono", "emoji", "symbol", "math", "cjk", "arabic", "hebrew", "thai", "devanagari", "italic", "oblique", "bold", "light", "thin", "black", "condensed"}
	for path in files {
		stem := strings.to_lower(filepath.stem(path), context.temp_allocator)
		usable := true
		for word in SKIP {
			if strings.contains(stem, word) {
				usable = false
				break
			}
		}
		if usable && face_load(f, face, path) {
			return
		}
	}
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
	// macOS's own, found only there: Hebrew with zero-advance points, then
	// Arial Unicode for Arabic presentation forms and most else; CJK, Hangul
	// and symbols.
	"SFHebrew",
	"Arial Unicode",
	"Hiragino Sans GB",
	"AppleSDGothicNeo",
	"Apple Symbols",
}

// load_fallback_font appends a face to the fallback chain. An application only
// needs this for a script the automatic scan did not find a font for; the
// chain is searched in the order faces are added.
load_fallback_font :: proc(f: ^Fonts, path: string) -> bool {
	face: Face
	if !face_load_relocated(f, &face, path) {
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
// must not become tofu: zero-width joiners, the variation selectors and the
// tag characters that emoji sequences are glued together with. Inside a
// sequence the emoji font's GSUB consumes them (emoji_compose); anywhere else
// they draw nothing, which is what they are for.
@(private)
is_ignorable :: proc "contextless" (r: rune) -> bool {
	switch {
	case r >= 0x200b && r <= 0x200f: // ZWSP, ZWNJ, ZWJ, LRM, RLM
		return true
	case r == 0x2060, r == 0xfeff: // word joiner, BOM
		return true
	case r >= 0xfe00 && r <= 0xfe0f: // variation selectors 1-16
		return true
	case r >= 0xe0000 && r <= 0xe0fff: // tags, variation selectors 17-256
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

// face_load_relocated is face_load with the by-name second look load_font
// describes. The scan only runs on a miss, so a path that exists costs nothing
// extra, and a name found in several directories resolves to the first one
// font_dirs lists -- the system directories before the user's.
@(private)
face_load_relocated :: proc(f: ^Fonts, face: ^Face, path: string) -> bool {
	if face_load(f, face, path) {
		return true
	}
	if os.exists(path) {
		// The file is there and is not a font: another copy will not be either.
		return false
	}
	name := filepath.base(path)
	files := scan_font_files()
	defer {
		for p in files {
			delete(p)
		}
		delete(files)
	}
	for p in files {
		if filepath.base(p) == name && face_load(f, face, p) {
			return true
		}
	}
	return false
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
//
// `dir` is the base direction the line inherits from its paragraph, and only
// matters for text that reorders; see the bidirectional section below. The
// width of a reordered line is not the width of the same characters laid out in
// storage order — shaping changes which glyphs are drawn, and kerning applies
// to a different set of pairs — so this cannot be answered without doing the
// reordering, and it is done by the same procedure the drawing uses.
text_width :: proc(
	f: ^Fonts,
	text: string,
	size: f32,
	fam := Font_Family.Sans,
	wt := Font_Weight.Regular,
	tracking: f32 = 0,
	sl := Font_Slant.Upright,
	tabular := false,
	dir := Bidi_Direction.Auto,
) -> f32 {
	face := &f.faces[fam][wt][sl]
	if !face.ok {
		ascii := fallback_ascii(text)
		return f32(ef.width(ascii)) * fallback_scale(size) + f32(len(ascii)) * tracking
	}
	if !text_simple(text, dir) {
		return text_width_complex(
			f,
			text,
			text_base_dir(text, dir),
			text_style(f, size, fam, wt, sl, tracking, tabular),
		)
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
	dir := Bidi_Direction.Auto,
) -> f32 {
	face := &f.faces[fam][wt][sl]
	if !face.ok {
		return draw_text_fallback(c, text, x, y, size, col)
	}
	if !text_simple(text, dir) {
		return draw_text_complex(
			c,
			f,
			text,
			x,
			y,
			col,
			text_base_dir(text, dir),
			text_style(f, size, fam, wt, sl, tracking, tabular),
			outline,
		)
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
	dir := Bidi_Direction.Auto,
) -> f32 {
	return draw_text(
		c, f, text, x, y, size, col, fam, wt, tracking, sl, tabular,
		Text_Outline{width = outline_w, color = outline_col}, dir,
	)
}

// draw_text_fallback renders with the built-in vector-segment font, used only
// when no font file could be found on the system.
@(private)
draw_text_fallback :: proc(c: ^Canvas, text_in: string, x, y, size: f32, col: Color) -> f32 {
	text := fallback_ascii(text_in)
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

// fallback_ascii is the text as the built-in font can draw it: one '?' per
// rune outside printable ASCII. stb_easy_font indexes a 96-entry table by
// byte with no bounds check of its own, so the first em dash or accented
// letter in an interface -- every application has some -- was an
// out-of-range panic on exactly the system that has no fonts installed,
// which is the system where the fallback is the only thing on screen.
@(private)
fallback_ascii :: proc(text: string) -> string {
	clean := true
	for i in 0 ..< len(text) {
		if text[i] < 0x20 || text[i] > 0x7e {
			clean = false
			break
		}
	}
	if clean {
		return text
	}
	b := strings.builder_make(0, len(text), context.temp_allocator)
	for r in text {
		strings.write_byte(&b, r >= 0x20 && r <= 0x7e ? u8(r) : '?')
	}
	return strings.to_string(b)
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
	dir := Bidi_Direction.Auto,
) -> int {
	if len(text) == 0 {
		return 0
	}
	if !text_simple(text, dir) {
		// Once a line reorders, walking forward from the left and stopping at
		// a midpoint gives an index from the wrong end of the string. The
		// visual answer, and the affinity that goes with it, is
		// `text_index_at_affinity`; this is that with the affinity dropped,
		// which is all an existing caller can use.
		i, _ := text_index_at_affinity(f, text, size, x, fam, wt, tracking, sl, tabular, dir)
		return i
	}
	if x <= 0 {
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
//
// For text laid out left to right that is the whole story and this is still
// literally the width of the prefix, which is what the forty-odd callers of it
// mean. For text that reorders it is not: `text[:index]` can contain characters
// drawn to the right of the caret, so the prefix has no edge to measure and the
// question has to be asked of the visual runs instead. Such a string is handed
// to `text_caret_x`, which is the honest form of this procedure and takes the
// affinity a direction boundary needs.
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
	dir := Bidi_Direction.Auto,
) -> f32 {
	i := clamp(index, 0, len(text))
	if !text_simple(text, dir) {
		return text_caret_x(f, text, i, size, .Downstream, fam, wt, tracking, sl, tabular, dir)
	}
	return text_width(f, text[:i], size, fam, wt, tracking, sl, tabular)
}

// ---------------------------------------------------------------------------
// Bidirectional and shaped text
//
// Everything above this line walks a string's codepoints in storage order and
// treats that as the order they appear on screen. For Latin it is; for Hebrew
// and Arabic it is backwards, and for Arabic it is also the wrong glyphs, since
// the letters are cursive and palmy draws one glyph per codepoint.
//
// `bidi.odin` and `shape.odin` answer both halves of that, and this section is
// where they meet the font: one procedure, `text_layout_line`, turns a string
// into the glyphs that will actually be drawn, in the order they will actually
// be drawn, each with the x it will be drawn at and the source bytes it came
// from. Measuring, drawing, hit testing, caret placement and selection all read
// that one list, which is the only way they can agree — and they have to agree,
// because a caret that disagrees with the glyphs is worse than no bidi at all.
//
// THE ORDER OF OPERATIONS, which is where this goes wrong silently:
//
//   1. The base level comes from the *paragraph*; the resolution happens per
//      *line*. `dir` is threaded through every entry point for exactly that:
//      a wrapper computes `bidi_base_level` over the whole paragraph once and
//      passes `bidi_direction_for_level` of it to each line. Resolving a line
//      `.Auto` lets one that begins with a Latin word flip the whole line.
//   2. Shape in logical order, then reverse. Arabic joining is a property of
//      logical neighbours, so the shaper runs over the run as stored and the
//      glyph sequence is reversed afterwards for a right-to-left run. Reversing
//      first gives initial forms where final ones belong.
//   3. A shaped presentation form is never mirrored. `bidi_mirror` is for
//      brackets and the like; an Arabic letter already points the right way,
//      and U+FEE0 has no mirror to find anyway.
//   4. Kerning is between *visually* adjacent glyphs. The pen carries the
//      previous glyph in visual order across run boundaries, because that is
//      the pair that is actually next to each other on screen.
//   5. The directional controls get a glyph with zero advance rather than no
//      glyph: they must not draw (they have no outline, so they would be
//      .notdef boxes) but they must still own their bytes, or a caret offset
//      inside one has nothing to map to.
//   6. The fast path stays exact. `text_simple` is one pass of byte
//      comparisons for ASCII, and a string it approves of goes down the
//      original loops untouched. Text measurement runs several times per frame
//      per node, and every parity case in the repository is Latin.
//
// Allocation is zero per call after warm-up: the `Bidi_Scratch` and the glyph
// buffer live on `Fonts` and are cleared and refilled. The corollary is that
// the glyph list is only valid until the next call, so none of these
// procedures may be called from inside a loop over another's result.
// ---------------------------------------------------------------------------

// Caret_Affinity resolves the one thing a byte offset cannot say on its own.
//
// At a direction boundary a single logical index has *two* valid positions on
// screen. In `abc` followed by Hebrew `אבג`, the offset just after `c` is both
// the right edge of `c` and the right edge of `א` — the same character offset,
// two places, and no amount of further measurement decides between them,
// because the information is not in the string. It comes from how the caret got
// there: typing after `c` means one, clicking to the right of `א` means the
// other.
//
// So the affinity travels beside the index:
//
//   Downstream  the caret precedes the character *at* `index`, and is drawn at
//               that character's leading edge — its left side in a
//               left-to-right run, its right side in a right-to-left one.
//   Upstream    the caret follows the character *before* `index`, and is drawn
//               at that character's trailing edge.
//
// For text with one direction the two agree everywhere, which is why every
// entry point defaults to `Downstream` and why nothing already written needs to
// care.
Caret_Affinity :: enum u8 {
	Downstream,
	Upstream,
}

// Text_Glyph is one glyph of a laid-out line: what to draw, where, and which
// bytes of the original string it stands for.
//
// The list is in visual order, left to right. `x` and `adv` tile the line
// without gaps — `adv` includes the kern applied in front of the glyph — so hit
// testing is a search for the box containing a coordinate, and `dx` is the
// offset from the box to where the glyph is actually painted.
//
// `src` and `size` are the inverse of the whole transformation, and the only
// way back. A lam-alef ligature has `size` spanning two letters, which is why a
// byte offset cannot be recovered from the drawn codepoint alone.
Text_Glyph :: struct {
	cp:     rune, // the codepoint drawn: a presentation form, a mirror, or the source rune
	src:    int,  // byte offset in the source string of the first rune behind it
	size:   int,  // source bytes it *owns*; more than one rune for a ligature, and
	              // zero for a mark drawn from inside a ligature that owns them
	              // already. The spans partition the string, which is what lets a
	              // byte offset name exactly one glyph.
	x:      f32,  // left edge of its advance box, relative to the line origin
	adv:    f32,  // width of that box: kern + advance + tracking
	dx:     f32,  // where inside the box the glyph is painted
	level:  u8,   // the embedding level of its run
	rtl:    bool, // that level is odd
	shaped: bool, // `cp` is a presentation form, so it must not be mirrored
	mark:   bool, // a combining mark, which stays with the base before it
	emoji:  bool, // drawn by the colour bitmap font
	blank:  bool, // zero advance, nothing drawn: a control or a default-ignorable
	gid:    u32,  // an emoji sequence GSUB composed: the colour font's glyph id,
	              // standing for every rune in the span (see emoji_compose)
}

// Text_Span is one rectangle's horizontal extent, relative to the line origin.
// A selection is a list of these rather than a single pair of edges, because a
// logical range that crosses a direction boundary is discontiguous on screen.
Text_Span :: struct {
	x, w: f32,
}

// Caret_Step is a direction on screen, not in the string. Arrow keys are the
// one place a text field has to choose: logical movement steps the byte offset,
// visual movement steps left and right as the reader sees them, and inside a
// right-to-left run those are opposites. Most toolkits use visual for the arrow
// keys and logical for word jumps; `text_caret_move` is the visual one.
Caret_Step :: enum u8 {
	Left,
	Right,
}

// Text_Shaper is the per-`Fonts` scratch. A zeroed one self-initialises on
// first use, so nothing has to remember to set it up.
@(private)
Text_Shaper :: struct {
	bidi:     Bidi_Scratch,
	glyphs:   [dynamic]Text_Glyph,
	// Scratch for composing emoji sequences, kept so that a line with one in
	// it allocates nothing after the first.
	composed: [dynamic]Text_Glyph,
	gsub_buf: [dynamic]Gsub_Glyph,
	ready:    bool,
}

@(private)
text_shaper :: proc(f: ^Fonts) -> ^Text_Shaper {
	if !f.shaper.ready {
		bidi_scratch_init(&f.shaper.bidi)
		f.shaper.glyphs = make([dynamic]Text_Glyph)
		f.shaper.ready = true
	}
	return &f.shaper
}

@(private)
text_shaper_destroy :: proc(f: ^Fonts) {
	if !f.shaper.ready {
		return
	}
	bidi_scratch_destroy(&f.shaper.bidi)
	delete(f.shaper.glyphs)
	delete(f.shaper.composed)
	delete(f.shaper.gsub_buf)
	f.shaper = {}
}

// Text_Style is the measurement half of the parameter list, gathered up once so
// the placement pass does not take eight arguments and so the tabular slot is
// looked up once per line rather than once per digit.
@(private)
Text_Style :: struct {
	size:     f32,
	tracking: f32,
	slot:     f32,
	fam:      Font_Family,
	wt:       Font_Weight,
	sl:       Font_Slant,
	tabular:  bool,
}

@(private)
text_style :: proc(
	f: ^Fonts,
	size: f32,
	fam: Font_Family,
	wt: Font_Weight,
	sl: Font_Slant,
	tracking: f32,
	tabular: bool,
) -> Text_Style {
	return Text_Style {
		size     = size,
		tracking = tracking,
		slot     = tabular ? tabular_slot(f, fam, wt, sl, size) : 0,
		fam      = fam,
		wt       = wt,
		sl       = sl,
		tabular  = tabular,
	}
}

// text_simple reports that a string can go down the original one-run path: its
// visual order is its logical order and no glyph substitution applies to it.
//
// Both halves have to hold. `bidi_cannot_reorder` is a byte scan that no ASCII
// string escapes; `needs_arabic_shaping` is another, keyed on the two lead
// bytes the shapable letters live behind. A forced right-to-left base direction
// fails immediately whatever the text says, because an empty or all-neutral
// line still has to be laid out from the right.
@(private)
text_simple :: proc "contextless" (text: string, dir: Bidi_Direction) -> bool {
	if dir == .RTL {
		return false
	}
	return bidi_cannot_reorder(text) && !needs_arabic_shaping(text) && !has_emoji_sequence(text)
}

// text_base_dir resolves a paragraph's base direction to the forced direction
// its lines should each be resolved with. Pass the whole paragraph, use the
// answer for every line of it.
text_base_dir :: proc(text: string, dir := Bidi_Direction.Auto) -> Bidi_Direction {
	return bidi_direction_for_level(bidi_base_level(text, dir))
}

// text_base_rtl reports whether a line's own base direction is right to left,
// which is what decides where `start` alignment puts it and where an empty
// field parks its caret. `bidi_base_level("")` with `.RTL` is 1 for that
// reason: an empty right-to-left search box still wants its caret on the right.
text_base_rtl :: proc(text: string, dir := Bidi_Direction.Auto) -> bool {
	return bidi_is_rtl(bidi_base_level(text, dir))
}

// text_layout_line resolves, shapes and places one line, and is the single
// source of truth every other procedure in this section reads.
//
// The returned slice aliases the scratch on `f` and is invalidated by the next
// call. `total` is the line's advance, including the allowance a synthetic bold
// makes for being overprinted.
@(private)
text_layout_line :: proc(
	f: ^Fonts,
	text: string,
	dir: Bidi_Direction,
	st: Text_Style,
) -> (glyphs: []Text_Glyph, layout: Bidi_Layout, total: f32) {
	sh := text_shaper(f)
	layout = bidi_resolve(text, dir, &sh.bidi)
	clear(&sh.glyphs)

	// --- order and shape -------------------------------------------------
	// One run at a time, in the visual order L2 put them in. Within a run the
	// shaper walks the bytes as stored, because that is the order joining is
	// defined over, and the glyphs it produced are reversed afterwards if the
	// run runs right to left.
	for run in layout.runs {
		rtl := bidi_is_rtl(run.level)
		sub := text[run.start:run.end]
		first := len(sh.glyphs)
		sc := Shape_Ctx{}
		// One past the last byte owned by a lam-alef ligature already emitted.
		// A ligature's span covers everything between its lam and its alef,
		// including any harakat that stood between the two letters -- and the
		// shaper then emits those marks as glyphs of their own, from *inside*
		// that span, so that no codepoint is lost. Both are right, and taking
		// both at face value would have the same byte claimed by two glyphs:
		// `text_glyph_for` would answer with whichever one visual order
		// happened to put first, and a selection would measure it twice. The
		// ligature keeps the bytes; the mark keeps its ink and claims nothing.
		lig_end := 0
		for {
			sr, done := shape_step(sub, &sc, DEFAULT_SHAPE_OPTIONS)
			if done {
				break
			}
			cp := sr.cp
			ctl := bidi_is_control(cp)
			// Rule L4, and only for what was not already shaped: a bracket in
			// a right-to-left run is drawn as its mirror, an Arabic
			// presentation form is drawn as itself.
			if rtl && !sr.shaped && !ctl {
				cp = bidi_mirror(cp)
			}
			size := sr.size
			switch {
			case sr.lig:
				lig_end = sr.src + sr.size
			case sr.src < lig_end:
				size = 0
			}
			append(
				&sh.glyphs,
				Text_Glyph {
					cp     = cp,
					src    = run.start + sr.src,
					size   = size,
					level  = run.level,
					rtl    = rtl,
					shaped = sr.shaped,
					mark   = !sr.shaped && bidi_class(sr.cp) == .NSM,
					blank  = ctl,
				},
			)
		}
		// Emoji sequences are composed in logical order, before a
		// right-to-left run is turned round, so that the font sees "👨 ZWJ 💻"
		// and the composed glyph is reversed as the one unit it now is.
		if has_emoji_sequence(sub) {
			Compose_Ctx :: struct {
				f:    ^Fonts,
				text: string,
				st:   Text_Style,
			}
			cc := Compose_Ctx{f, text, st}
			starts :: proc(g: Text_Glyph, user: rawptr) -> bool {
				cc := (^Compose_Ctx)(user)
				pe := prefers_emoji(cc.text, g.src, g.cp)
				return resolve_rune(cc.f, cc.st.fam, cc.st.wt, cc.st.sl, g.cp, pe).emoji
			}
			emoji_compose(&f.emoji, &sh.glyphs, first, &sh.composed, &sh.gsub_buf, starts, &cc)
		}
		if rtl {
			text_reverse_clusters(sh.glyphs[first:])
		}
	}

	// --- place -------------------------------------------------------------
	// The pen walks the list in visual order, so `prev` is the glyph to the
	// left of this one on screen and the kern pair is the one the reader sees.
	// It deliberately survives a run boundary: two runs are drawn flush
	// against each other, so their touching glyphs are a visual pair.
	pen := f32(0)
	prev := rune(0)
	prev_face: ^Face = nil
	// Where the base of the cluster being placed was drawn, for the marks that
	// follow it.
	base_x := f32(0)
	for i in 0 ..< len(sh.glyphs) {
		g := &sh.glyphs[i]
		g.x = pen
		if g.blank {
			prev, prev_face = 0, nil
			continue
		}
		if g.gid != 0 {
			// Composed by emoji_compose: already a glyph of the colour font.
			g.emoji = true
			g.adv = emoji_glyph_advance(&f.emoji, g.gid, st.size) + st.tracking
			base_x = g.x
			pen += g.adv
			prev, prev_face = 0, nil
			continue
		}
		// The emoji question is asked of the source string, where the
		// variation selector that answers it still follows the rune. A shaped
		// form is never an emoji, and `cp` is not what is in the string.
		pe := !g.shaped && prefers_emoji(text, g.src, g.cp)
		rs := resolve_rune(f, st.fam, st.wt, st.sl, g.cp, pe)
		if rs.blank {
			g.blank = true
			prev, prev_face = 0, nil
			continue
		}
		if rs.emoji {
			g.emoji = true
			g.adv = emoji_advance(&f.emoji, g.cp, st.size) + st.tracking
			base_x = g.x
			pen += g.adv
			prev, prev_face = 0, nil
			continue
		}
		rf := rs.face
		s := face_scale(rf, st.size)
		adv, lsb: i32
		tt.GetCodepointHMetrics(&rf.info, g.cp, &adv, &lsb)
		if st.tabular && is_digit(g.cp) {
			// Centred in the slot the measurement committed to, exactly as the
			// simple path does it.
			g.dx = (st.slot - f32(adv) * s) / 2
			g.adv = st.slot + st.tracking
			base_x = g.x + g.dx
			pen += g.adv
			prev, prev_face = g.cp, rf
			continue
		}
		kern := f32(0)
		if prev != 0 && !f.no_kerning && prev_face == rf && !(st.tabular && is_digit(prev)) {
			kern = f32(tt.GetCodepointKernAdvance(&rf.info, prev, g.cp)) * s
		}
		g.dx = kern
		g.adv = kern + f32(adv) * s + st.tracking
		if g.mark && adv == 0 {
			// A combining mark with no advance is drawn at the origin of the
			// base it belongs to, not at the pen that base left behind.
			//
			// This is as close to mark positioning as palmy gets, and it is a
			// font convention rather than a rule: the Noto faces that carry
			// Hebrew and Arabic are positioned by GPOS, so their marks are
			// drawn around the base's own origin -- Noto's shin dot has its ink
			// from x=20 to x=23 against a shin 22.67 wide, which is over the
			// right arm exactly where it belongs, and only if the pen is still
			// at the shin. (The other convention, a mark whose ink sits to the
			// *left* of the pen so that it backs up over the base already
			// drawn, is what the Latin combining marks in DejaVu do -- and
			// those never reach here, because text that is only Latin and marks
			// cannot reorder and takes the fast path, which draws them that way
			// already.)
			g.dx = base_x - g.x
		} else {
			base_x = g.x + kern
		}
		pen += g.adv
		prev, prev_face = g.cp, rf
	}

	total = pen
	if f.faces[st.fam][st.wt][st.sl].synth_bold {
		total += st.size * 0.02
	}
	return sh.glyphs[:], layout, total
}

// text_reverse_clusters reverses a right-to-left run for display, keeping each
// base character and the combining marks that follow it together and in that
// order.
//
// This is rule L3, which `bidi.odin` deliberately leaves to whatever knows how
// marks attach -- and which is not optional here. A plain reversal puts a mark
// *before* its base, and palmy draws a mark with the font's own advance and no
// GPOS attachment, so "before" means over the previous letter: vocalised Hebrew
// and Arabic come out with every point one letter to the left of where it
// belongs. Reversing the run and then turning each cluster back round leaves
// the bases in visual order and the marks on the base they came from.
@(private)
text_reverse_clusters :: proc(gs: []Text_Glyph) {
	for a, b := 0, len(gs) - 1; a < b; a, b = a + 1, b - 1 {
		gs[a], gs[b] = gs[b], gs[a]
	}
	// After the reversal a cluster reads marks first and its base last.
	i := 0
	for i < len(gs) {
		j := i
		for j < len(gs) && gs[j].mark {
			j += 1
		}
		if j < len(gs) {
			j += 1 // the base the marks belong to
		}
		for a, b := i, j - 1; a < b; a, b = a + 1, b - 1 {
			gs[a], gs[b] = gs[b], gs[a]
		}
		i = j
	}
}

// text_glyph_caret_x is the x of a caret at source byte offset `i` inside one
// glyph's box.
//
// At the two ends of a single-rune glyph this is just the leading or trailing
// edge, flipped for a right-to-left run. Inside a ligature it interpolates: a
// lam-alef is one glyph standing for two letters, there is no edge between them
// to measure, and a caret between the lam and the alef has to go somewhere
// defensible. Half way is the honest answer.
@(private)
text_glyph_caret_x :: proc(g: Text_Glyph, i: int) -> f32 {
	frac := f32(0)
	if g.size > 0 {
		frac = clamp(f32(i - g.src) / f32(g.size), 0, 1)
	}
	if g.rtl {
		return g.x + g.adv * (1 - frac)
	}
	return g.x + g.adv * frac
}

// text_glyph_for finds the glyph a logical byte offset belongs to.
//
// `trailing` picks which side of a boundary to look at, and is the whole of
// what affinity does: `Downstream` wants the glyph whose span *starts* at the
// offset, `Upstream` the glyph whose span *ends* there. At a direction boundary
// those are two different glyphs in two different places.
@(private)
text_glyph_for :: proc(glyphs: []Text_Glyph, i: int, trailing: bool) -> int {
	for g, gi in glyphs {
		if trailing {
			if i > g.src && i <= g.src + g.size {
				return gi
			}
		} else {
			if i >= g.src && i < g.src + g.size {
				return gi
			}
		}
	}
	return -1
}

// text_width_complex measures a line that needed resolving. It is
// `text_layout_line` and nothing else, which is the point: the width a caller
// centres or wraps on is the sum of the advances the drawing will use, computed
// by the same code, so the two cannot drift.
@(private)
text_width_complex :: proc(f: ^Fonts, text: string, dir: Bidi_Direction, st: Text_Style) -> f32 {
	_, _, total := text_layout_line(f, text, dir, st)
	return total
}

// draw_text_complex draws a resolved, shaped line. The glyph rasterisation is
// the simple path's, verbatim; only the order of the glyphs and the source of
// the pen positions differ.
@(private)
draw_text_complex :: proc(
	c: ^Canvas,
	f: ^Fonts,
	text: string,
	x, y: f32,
	col: Color,
	dir: Bidi_Direction,
	st: Text_Style,
	outline: Text_Outline,
) -> f32 {
	glyphs, _, total := text_layout_line(f, text, dir, st)
	stroke := outline.width > 0 && outline.color.a > 0

	for g in glyphs {
		if g.blank {
			continue
		}
		gpen := x + g.x + g.dx
		if g.emoji {
			gid := g.gid != 0 ? g.gid : emoji_glyph(&f.emoji, g.cp)
			emoji_draw_glyph(c, &f.emoji, gid, gpen, y, st.size, col.a)
			continue
		}
		rf := resolve_rune(f, st.fam, st.wt, st.sl, g.cp).face

		base := math.floor(gpen)
		frac := gpen - base
		phase := u8(clamp(frac * SUBPIXEL_PHASES, 0, SUBPIXEL_PHASES - 1))
		key := glyph_key(g.cp, st.size, st.fam, st.wt, phase, st.sl)

		if stroke {
			o := outline_glyph_for(f, key, outline.width)^
			if o.mask != nil {
				ox := int(base) + o.xoff
				oy := int(math.round(y)) + o.yoff
				blit_mask(c, ox, oy, o.mask, o.w, o.h, outline.color)
				if rf.synth_bold {
					blit_mask(c, ox + 1, oy, o.mask, o.w, o.h, outline.color)
				}
			}
		}
		gl := glyph_for_key(f, key)^
		if gl.mask != nil {
			px := int(base) + gl.xoff
			py := int(math.round(y)) + gl.yoff
			blit_mask(c, px, py, gl.mask, gl.w, gl.h, col)
			if rf.synth_bold {
				blit_mask(c, px + 1, py, gl.mask, gl.w, gl.h, col)
			}
		}
	}
	return total
}

// text_caret_x is where the caret sits for a logical byte offset, measured from
// the line origin.
//
// This is the procedure `text_width_upto` wanted to be and could not: once a
// line reorders, the caret's x stops being a function of the prefix of the
// string, because `text[:index]` contains characters that are drawn to the
// *right* of the caret. The answer is an edge of a glyph in the visual list,
// and which edge is what `affinity` says.
text_caret_x :: proc(
	f: ^Fonts,
	text: string,
	index: int,
	size: f32,
	affinity := Caret_Affinity.Downstream,
	fam := Font_Family.Sans,
	wt := Font_Weight.Regular,
	tracking: f32 = 0,
	sl := Font_Slant.Upright,
	tabular := false,
	dir := Bidi_Direction.Auto,
) -> f32 {
	i := clamp(index, 0, len(text))
	face := &f.faces[fam][wt][sl]
	if !face.ok || text_simple(text, dir) {
		// Unchanged for text that cannot reorder: the prefix width is the
		// caret, and both affinities give the same number.
		return text_width_upto(f, text, i, size, fam, wt, tracking, sl, tabular)
	}

	st := text_style(f, size, fam, wt, sl, tracking, tabular)
	glyphs, layout, total := text_layout_line(f, text, text_base_dir(text, dir), st)
	rtl := bidi_layout_rtl(layout)
	if len(glyphs) == 0 {
		// An empty line parks the caret on the side its base direction starts
		// from, which for a right-to-left field is the right.
		return rtl ? total : 0
	}

	// The two ends of the string have only one answer each, whatever the
	// caller asked for: there is no character at `len(text)` to be downstream
	// of, and none before 0 to be upstream of.
	aff := affinity
	switch {
	case i >= len(text):
		aff = .Upstream
	case i <= 0:
		aff = .Downstream
	}
	if gi := text_glyph_for(glyphs, i, aff == .Upstream); gi >= 0 {
		return text_glyph_caret_x(glyphs[gi], i)
	}
	// Only reachable for an offset no glyph claims, which means an empty run
	// list or an index past the end of a shorter string than was resolved.
	return rtl ? 0 : total
}

// text_index_at_affinity is `text_index_at` with the answer it had to throw
// away: which side of the character the hit landed on, and therefore which of
// the two visual positions a boundary offset means.
//
// Inside a right-to-left run the logical index *decreases* as x increases, so
// the midpoint test flips: a hit on the right half of a right-to-left character
// is a caret before it, not after it.
text_index_at_affinity :: proc(
	f: ^Fonts,
	text: string,
	size: f32,
	x: f32,
	fam := Font_Family.Sans,
	wt := Font_Weight.Regular,
	tracking: f32 = 0,
	sl := Font_Slant.Upright,
	tabular := false,
	dir := Bidi_Direction.Auto,
) -> (index: int, affinity: Caret_Affinity) {
	face := &f.faces[fam][wt][sl]
	if !face.ok || text_simple(text, dir) {
		return text_index_at(f, text, size, x, fam, wt, tracking, sl, tabular), .Downstream
	}

	st := text_style(f, size, fam, wt, sl, tracking, tabular)
	glyphs, layout, _ := text_layout_line(f, text, text_base_dir(text, dir), st)
	if len(glyphs) == 0 {
		return 0, .Downstream
	}

	// The boxes tile the line, so a coordinate inside it lands in exactly one
	// of them. Zero-width boxes — the controls, the variation selectors — sit
	// on the boundaries and are never what was clicked on.
	hit, last := -1, -1
	for g, gi in glyphs {
		if g.adv <= 0 {
			continue
		}
		last = gi
		if x < g.x + g.adv {
			hit = gi
			break
		}
	}
	if hit < 0 {
		hit = last
	}
	if hit < 0 {
		// Nothing drawable on the line at all.
		return bidi_layout_rtl(layout) ? len(text) : 0, .Downstream
	}

	g := glyphs[hit]
	left_half := x < g.x + g.adv / 2
	if g.rtl {
		// The leading edge of a right-to-left glyph is its *right* side.
		if left_half {
			return g.src + g.size, .Upstream
		}
		return g.src, .Downstream
	}
	if left_half {
		return g.src, .Downstream
	}
	return g.src + g.size, .Upstream
}

// text_selection_spans fills `out` with the rectangles that highlight the
// logical byte range `lo..hi`, and returns how many it wrote.
//
// A selection stops being one rectangle the moment a range crosses a direction
// boundary: the characters are contiguous in the string and in two places on
// screen. Visually adjacent runs of selected glyphs are merged, so selecting a
// whole mixed line is still one rectangle, and selecting across its boundary is
// two. Two spans is enough for one boundary; a line alternating direction
// several times needs more, and a caller that passes a short buffer gets the
// leftmost spans and a count equal to its length.
text_selection_spans :: proc(
	f: ^Fonts,
	text: string,
	lo, hi: int,
	size: f32,
	out: []Text_Span,
	fam := Font_Family.Sans,
	wt := Font_Weight.Regular,
	tracking: f32 = 0,
	sl := Font_Slant.Upright,
	tabular := false,
	dir := Bidi_Direction.Auto,
) -> int {
	if len(out) == 0 {
		return 0
	}
	a := clamp(min(lo, hi), 0, len(text))
	b := clamp(max(lo, hi), 0, len(text))
	if a == b {
		return 0
	}

	face := &f.faces[fam][wt][sl]
	if !face.ok || text_simple(text, dir) {
		x0 := text_width_upto(f, text, a, size, fam, wt, tracking, sl, tabular)
		x1 := text_width_upto(f, text, b, size, fam, wt, tracking, sl, tabular)
		out[0] = {x0, x1 - x0}
		return 1
	}

	st := text_style(f, size, fam, wt, sl, tracking, tabular)
	glyphs, _, _ := text_layout_line(f, text, text_base_dir(text, dir), st)
	n := 0
	for g in glyphs {
		// A glyph that owns no bytes -- a mark the ligature around it already
		// accounts for -- cannot intersect a byte range, and measuring it
		// again would highlight the same ink twice.
		if g.adv <= 0 || g.size <= 0 || g.src + g.size <= a || g.src >= b {
			continue
		}
		// A ligature only partly inside the range is highlighted in
		// proportion, for the same reason the caret inside one is
		// interpolated: there is no edge between its letters.
		s := max(g.src, a)
		e := min(g.src + g.size, b)
		x0 := text_glyph_caret_x(g, s)
		x1 := text_glyph_caret_x(g, e)
		if x0 > x1 {
			x0, x1 = x1, x0
		}
		if n > 0 && abs(out[n - 1].x + out[n - 1].w - x0) <= 0.01 {
			out[n - 1].w = x1 - out[n - 1].x
			continue
		}
		if n >= len(out) {
			break
		}
		out[n] = {x0, x1 - x0}
		n += 1
	}
	return n
}

// text_caret_move steps the caret one character to the left or the right *on
// screen*, which in a right-to-left run is the opposite of stepping the byte
// offset.
//
// The caret is identified by the glyph it is attached to and the side of it,
// which is what the index and affinity together say. Moving crosses exactly one
// glyph, and the caret arrives on its far side — stated in terms of that
// glyph's own direction, so the returned affinity is the one that puts the
// caret back where this procedure left it. At either end of the line the caret
// does not move and the input comes back unchanged, which is the signal to try
// the next line.
text_caret_move :: proc(
	f: ^Fonts,
	text: string,
	index: int,
	size: f32,
	step: Caret_Step,
	affinity := Caret_Affinity.Downstream,
	fam := Font_Family.Sans,
	wt := Font_Weight.Regular,
	tracking: f32 = 0,
	sl := Font_Slant.Upright,
	tabular := false,
	dir := Bidi_Direction.Auto,
) -> (int, Caret_Affinity) {
	i := clamp(index, 0, len(text))
	face := &f.faces[fam][wt][sl]
	if !face.ok || text_simple(text, dir) {
		// Visual movement is logical movement when nothing reorders.
		if step == .Right {
			if i >= len(text) {
				return i, affinity
			}
			_, n := utf8.decode_rune_in_string(text[i:])
			return i + max(n, 1), .Upstream
		}
		if i <= 0 {
			return i, affinity
		}
		_, n := utf8.decode_last_rune_in_string(text[:i])
		return i - max(n, 1), .Downstream
	}

	st := text_style(f, size, fam, wt, sl, tracking, tabular)
	glyphs, _, _ := text_layout_line(f, text, text_base_dir(text, dir), st)
	if len(glyphs) == 0 {
		return i, affinity
	}

	aff := affinity
	switch {
	case i >= len(text):
		aff = .Upstream
	case i <= 0:
		aff = .Downstream
	}
	cur := text_glyph_for(glyphs, i, aff == .Upstream)
	if cur < 0 {
		return i, affinity
	}

	// The caret's position between glyphs, counted in gaps: slot k sits between
	// glyph k-1 and glyph k. Which gap a (index, affinity) pair names depends
	// on the direction of the glyph it is attached to, because a right-to-left
	// glyph's leading edge is on its right.
	g := glyphs[cur]
	k := cur
	if (aff == .Downstream) == g.rtl {
		k = cur + 1
	}
	if aff == .Downstream && i > g.src && i < g.src + g.size {
		// Mid-ligature: moving leaves the ligature rather than splitting it
		// further, so snap to the side being moved towards.
		k = step == .Right ? cur + 1 : cur
		if g.rtl {
			k = step == .Right ? cur : cur + 1
		}
	}

	if step == .Right {
		for k < len(glyphs) && glyphs[k].adv <= 0 {
			k += 1
		}
		if k >= len(glyphs) {
			return i, affinity
		}
		crossed := glyphs[k]
		// The caret is now at the crossed glyph's right edge.
		if crossed.rtl {
			return crossed.src, .Downstream
		}
		return crossed.src + crossed.size, .Upstream
	}

	for k > 0 && glyphs[k - 1].adv <= 0 {
		k -= 1
	}
	if k <= 0 {
		return i, affinity
	}
	crossed := glyphs[k - 1]
	// And here at its left edge.
	if crossed.rtl {
		return crossed.src + crossed.size, .Upstream
	}
	return crossed.src, .Downstream
}

// text_glyphs lays out a line and hands back the glyph list, for the callers
// that genuinely need it: an editor drawing per-character decoration, a
// truncation that has to happen visually rather than on the logical prefix, or
// a test reading back what was drawn.
//
// The slice aliases scratch on `f` and the next text call overwrites it. Copy
// it or finish with it.
text_glyphs :: proc(
	f: ^Fonts,
	text: string,
	size: f32,
	fam := Font_Family.Sans,
	wt := Font_Weight.Regular,
	tracking: f32 = 0,
	sl := Font_Slant.Upright,
	tabular := false,
	dir := Bidi_Direction.Auto,
) -> (glyphs: []Text_Glyph, total: f32) {
	st := text_style(f, size, fam, wt, sl, tracking, tabular)
	g, _, w := text_layout_line(f, text, text_base_dir(text, dir), st)
	return g, w
}

