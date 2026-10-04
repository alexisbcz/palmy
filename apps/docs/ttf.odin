// A TrueType reader and subsetter, for PDF font embedding.
//
// palmy rasterizes with stb_truetype and keeps the face's bytes, but it does
// not expose glyph ids, hmtx advances or the table directory — and it should
// not: those are a PDF writer's problem, not a UI toolkit's. So this file
// parses the font file itself. It needs five things out of a face:
//
//   * `cmap`  — the rune → glyph id mapping, because an Identity-H PDF string
//               is a sequence of glyph ids, not of characters;
//   * `hmtx`  — advance widths, for the `/W` array and for the kerning
//               corrections the content stream emits;
//   * `head`/`hhea`/`OS/2`/`post` — the numbers a `/FontDescriptor` wants;
//   * `name`  — the PostScript name, which becomes `/BaseFont`;
//   * `loca`/`glyf` — the outlines, so they can be subset.
//
// ## How the subset works
//
// The usual subsetter renumbers glyphs and writes a compact font with a new
// `cmap`. This one does not, and deliberately: it keeps every glyph id where
// it was and empties the outlines of the glyphs the document never uses. The
// `loca` table still has `numGlyphs + 1` entries, but a dropped glyph's two
// entries are equal, so it occupies no bytes of `glyf`.
//
// That buys two things. Glyph ids stay stable, so `/Identity-H` can use them
// directly with `/CIDToGIDMap /Identity` and no mapping table anywhere; and
// composite glyphs keep working as long as their components are kept, which
// is one recursive walk rather than a renumbering pass over every component
// record. The cost is a `loca` and an `hmtx` of full length — tens of
// kilobytes at worst, against the hundreds that `glyf` would have been.
package main

import "core:os"
import "core:slice"
import "core:strings"

TTF :: struct {
	data:         []u8,
	ok:           bool,

	// Table directory, as (tag, offset, length).
	tables:       [dynamic]Ttf_Table,

	num_glyphs:   int,
	upem:         f32,
	loca_long:    bool,
	loca:         [dynamic]u32, // num_glyphs + 1 entries, offsets into glyf
	glyf_at:      int,
	glyf_len:     int,

	// hmtx, expanded: one advance per glyph, in font units.
	advances:     [dynamic]u16,

	// Numbers the /FontDescriptor needs, all in font units.
	x_min:        i16,
	y_min:        i16,
	x_max:        i16,
	y_max:        i16,
	ascent:       i16,
	descent:      i16,
	cap_height:   i16,
	italic_angle: f32,
	weight_class: int,
	fixed_pitch:  bool,
	ps_name:      string,

	// cmap: the chosen subtable, read on demand.
	cmap_at:      int,
	cmap_format:  int,
}

Ttf_Table :: struct {
	tag:       u32,
	at:        int,
	len:       int,
}

// ---------------------------------------------------------------------------
// Big-endian reads. Every one is bounds-checked and returns 0 past the end,
// so a truncated font produces a useless subset rather than a crash.
// ---------------------------------------------------------------------------

@(private = "file")
u8at :: proc(d: []u8, at: int) -> u8 {
	return at >= 0 && at < len(d) ? d[at] : 0
}

@(private = "file")
be16 :: proc(d: []u8, at: int) -> u16 {
	if at < 0 || at + 2 > len(d) {
		return 0
	}
	return u16(d[at]) << 8 | u16(d[at + 1])
}

@(private = "file")
bei16 :: proc(d: []u8, at: int) -> i16 {
	return i16(be16(d, at))
}

@(private = "file")
be32 :: proc(d: []u8, at: int) -> u32 {
	if at < 0 || at + 4 > len(d) {
		return 0
	}
	return u32(d[at]) << 24 | u32(d[at + 1]) << 16 | u32(d[at + 2]) << 8 | u32(d[at + 3])
}

tag_of :: proc(s: string) -> u32 {
	v := u32(0)
	for i in 0 ..< 4 {
		v = v << 8 | u32(i < len(s) ? s[i] : u8(' '))
	}
	return v
}

ttf_table :: proc(f: ^TTF, name: string) -> (at: int, length: int, ok: bool) {
	t := tag_of(name)
	for e in f.tables {
		if e.tag == t {
			return e.at, e.len, true
		}
	}
	return 0, 0, false
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

ttf_load :: proc(path: string) -> (f: TTF, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return {}, false
	}
	f.data = data
	if !ttf_parse(&f) {
		ttf_destroy(&f)
		return {}, false
	}
	return f, true
}

ttf_destroy :: proc(f: ^TTF) {
	delete(f.data)
	ttf_release(f)
}

// ttf_release frees everything the parser built but not the font bytes, for
// the case where those are borrowed rather than owned.
ttf_release :: proc(f: ^TTF) {
	delete(f.tables)
	delete(f.loca)
	delete(f.advances)
	delete(f.ps_name)
	f^ = {}
}

// ttf_from_bytes parses a font that is already in memory — a subset this file
// has just produced, say. The bytes are borrowed: free the result with
// `ttf_release`, never `ttf_destroy`.
ttf_from_bytes :: proc(data: []u8) -> (f: TTF, ok: bool) {
	f.data = data
	if !ttf_parse(&f) {
		ttf_release(&f)
		return {}, false
	}
	return f, true
}

@(private = "file")
ttf_parse :: proc(f: ^TTF) -> bool {
	d := f.data
	if len(d) < 12 {
		return false
	}
	ver := be32(d, 0)
	// 0x00010000 is TrueType outlines; "true" is the old Apple spelling.
	// "OTTO" is CFF, which cannot be embedded as /FontFile2 — refuse it
	// rather than write a PDF that renders nothing.
	if ver != 0x00010000 && ver != tag_of("true") {
		return false
	}
	n := int(be16(d, 4))
	f.tables = make([dynamic]Ttf_Table, 0, n)
	for i in 0 ..< n {
		rec := 12 + i * 16
		if rec + 16 > len(d) {
			return false
		}
		append(
			&f.tables,
			Ttf_Table{tag = be32(d, rec), at = int(be32(d, rec + 8)), len = int(be32(d, rec + 12))},
		)
	}

	head, _, has_head := ttf_table(f, "head")
	maxp, _, has_maxp := ttf_table(f, "maxp")
	hhea, _, has_hhea := ttf_table(f, "hhea")
	if !has_head || !has_maxp || !has_hhea {
		return false
	}

	f.upem = f32(be16(d, head + 18))
	if f.upem <= 0 {
		f.upem = 1000
	}
	f.x_min = bei16(d, head + 36)
	f.y_min = bei16(d, head + 38)
	f.x_max = bei16(d, head + 40)
	f.y_max = bei16(d, head + 42)
	f.loca_long = be16(d, head + 50) == 1
	f.num_glyphs = int(be16(d, maxp + 4))
	f.ascent = bei16(d, hhea + 4)
	f.descent = bei16(d, hhea + 6)
	num_hm := int(be16(d, hhea + 34))

	// loca, expanded to u32 so the rest of the file need not care which
	// format the original used.
	if loca, loca_len, has := ttf_table(f, "loca"); has {
		f.loca = make([dynamic]u32, 0, f.num_glyphs + 1)
		for i in 0 ..= f.num_glyphs {
			if f.loca_long {
				if loca + i * 4 + 4 > loca + loca_len {break}
				append(&f.loca, be32(d, loca + i * 4))
			} else {
				if loca + i * 2 + 2 > loca + loca_len {break}
				append(&f.loca, u32(be16(d, loca + i * 2)) * 2)
			}
		}
	}
	if glyf, glen, has := ttf_table(f, "glyf"); has {
		f.glyf_at, f.glyf_len = glyf, glen
	}
	if len(f.loca) != f.num_glyphs + 1 || f.glyf_len == 0 {
		return false // no outlines to embed
	}

	// hmtx: `num_hm` long/short pairs, then the last advance repeats.
	f.advances = make([dynamic]u16, 0, f.num_glyphs)
	if hmtx, _, has := ttf_table(f, "hmtx"); has && num_hm > 0 {
		last := u16(0)
		for g in 0 ..< f.num_glyphs {
			if g < num_hm {
				last = be16(d, hmtx + g * 4)
			}
			append(&f.advances, last)
		}
	} else {
		for _ in 0 ..< f.num_glyphs {
			append(&f.advances, u16(f.upem / 2))
		}
	}

	// OS/2 carries the cap height and the weight class when it is version 2
	// or later; before that, approximate from the ascender.
	f.cap_height = i16(f32(f.ascent) * 0.72)
	f.weight_class = 400
	if os2, os2_len, has := ttf_table(f, "OS/2"); has && os2_len >= 78 {
		f.weight_class = int(be16(d, os2 + 4))
		if be16(d, os2) >= 2 && os2_len >= 90 {
			if ch := bei16(d, os2 + 88); ch != 0 {
				f.cap_height = ch
			}
		}
	}
	if post, post_len, has := ttf_table(f, "post"); has && post_len >= 20 {
		// italicAngle is a 16.16 fixed-point degree count.
		f.italic_angle = f32(i32(be32(d, post + 4))) / 65536
		f.fixed_pitch = be32(d, post + 16) != 0
	}
	f.ps_name = ttf_ps_name(f)

	ttf_pick_cmap(f)
	return true
}

// ttf_ps_name reads name ID 6, the PostScript name, preferring the Windows
// UTF-16BE record. It is what `/BaseFont` is built from, and PDF names cannot
// hold spaces or delimiters, so the result is sanitised here.
@(private = "file")
ttf_ps_name :: proc(f: ^TTF) -> string {
	d := f.data
	fallback := "DocsEmbedded"
	nm, _, has := ttf_table(f, "name")
	if !has {
		return strings.clone(fallback)
	}
	count := int(be16(d, nm + 2))
	str_off := nm + int(be16(d, nm + 4))
	best := ""
	best_score := -1
	for i in 0 ..< count {
		rec := nm + 6 + i * 12
		plat := int(be16(d, rec))
		nid := int(be16(d, rec + 6))
		length := int(be16(d, rec + 8))
		off := str_off + int(be16(d, rec + 10))
		if nid != 6 || length == 0 || off + length > len(d) {
			continue
		}
		raw := d[off:off + length]
		b := strings.builder_make(context.temp_allocator)
		if plat == 3 || plat == 0 {
			// UTF-16BE; the PostScript name is ASCII, so take the low byte.
			for k := 1; k < len(raw); k += 2 {
				strings.write_byte(&b, raw[k])
			}
		} else {
			strings.write_bytes(&b, raw)
		}
		score := plat == 3 ? 2 : 1
		if score > best_score {
			best_score = score
			best = strings.to_string(b)
		}
	}
	if best == "" {
		return strings.clone(fallback)
	}
	out := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(best) {
		c := best[i]
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '+', '_':
			strings.write_byte(&out, c)
		}
	}
	s := strings.to_string(out)
	return strings.clone(len(s) > 0 ? s : fallback)
}

// ---------------------------------------------------------------------------
// cmap
// ---------------------------------------------------------------------------

// ttf_pick_cmap chooses the best subtable available: a format 12 Unicode
// table if the font has one (so astral characters work), otherwise a format 4
// BMP table, otherwise whatever is there.
@(private = "file")
ttf_pick_cmap :: proc(f: ^TTF) {
	d := f.data
	cm, _, has := ttf_table(f, "cmap")
	if !has {
		return
	}
	n := int(be16(d, cm + 2))
	best_score := -1
	for i in 0 ..< n {
		rec := cm + 4 + i * 8
		plat := int(be16(d, rec))
		enc := int(be16(d, rec + 2))
		sub := cm + int(be32(d, rec + 4))
		format := int(be16(d, sub))
		score := -1
		switch {
		case plat == 3 && enc == 10 && format == 12:
			score = 5
		case plat == 0 && format == 12:
			score = 4
		case plat == 3 && enc == 1 && format == 4:
			score = 3
		case plat == 0 && format == 4:
			score = 2
		case format == 6 || format == 4 || format == 12:
			score = 1
		case format == 0:
			score = 0
		}
		if score > best_score {
			best_score = score
			f.cmap_at = sub
			f.cmap_format = format
		}
	}
}

// ttf_gid maps a rune to a glyph id, 0 when the font has no glyph for it.
ttf_gid :: proc(f: ^TTF, r: rune) -> u16 {
	if f.cmap_at == 0 {
		return 0
	}
	d := f.data
	c := u32(r)
	switch f.cmap_format {
	case 0:
		if c > 255 {
			return 0
		}
		return u16(u8at(d, f.cmap_at + 6 + int(c)))
	case 4:
		if c > 0xffff {
			return 0
		}
		segs := int(be16(d, f.cmap_at + 6)) / 2
		ends := f.cmap_at + 14
		starts := ends + segs * 2 + 2
		deltas := starts + segs * 2
		ranges := deltas + segs * 2
		for s in 0 ..< segs {
			if u32(be16(d, ends + s * 2)) < c {
				continue
			}
			start := u32(be16(d, starts + s * 2))
			if c < start {
				return 0
			}
			ro := int(be16(d, ranges + s * 2))
			if ro == 0 {
				return u16(c + u32(be16(d, deltas + s * 2)))
			}
			at := ranges + s * 2 + ro + int(c - start) * 2
			g := be16(d, at)
			return g == 0 ? 0 : u16(u32(g) + u32(be16(d, deltas + s * 2)))
		}
		return 0
	case 6:
		first := u32(be16(d, f.cmap_at + 6))
		count := u32(be16(d, f.cmap_at + 8))
		if c < first || c >= first + count {
			return 0
		}
		return be16(d, f.cmap_at + 10 + int(c - first) * 2)
	case 12:
		groups := int(be32(d, f.cmap_at + 12))
		for g in 0 ..< groups {
			rec := f.cmap_at + 16 + g * 12
			lo := be32(d, rec)
			hi := be32(d, rec + 4)
			if c < lo {
				return 0
			}
			if c <= hi {
				return u16(be32(d, rec + 8) + (c - lo))
			}
		}
		return 0
	}
	return 0
}

// ttf_advance is a glyph's advance in 1000-unit em space, which is the unit
// a PDF `/W` array and a `Tj` adjustment both use.
ttf_advance :: proc(f: ^TTF, gid: u16) -> int {
	if int(gid) >= len(f.advances) {
		return 0
	}
	return int(f32(f.advances[gid]) * 1000 / f.upem + 0.5)
}

// to_em1000 converts a font-unit measurement to 1000-unit em space.
to_em1000 :: proc(f: ^TTF, v: i16) -> int {
	return int(f32(v) * 1000 / f.upem + (v >= 0 ? 0.5 : -0.5))
}

// ---------------------------------------------------------------------------
// Subsetting
// ---------------------------------------------------------------------------

// ttf_expand_composites grows a glyph set to include the components of every
// composite glyph in it. A composite glyph's outline is a list of references
// to other glyphs; dropping one of those leaves an "Ä" with no umlaut.
ttf_expand_composites :: proc(f: ^TTF, keep: ^map[u16]bool) {
	// A worklist, because a component can itself be composite.
	pending := make([dynamic]u16, 0, len(keep), context.temp_allocator)
	for g in keep {
		append(&pending, g)
	}
	for len(pending) > 0 {
		g := pop(&pending)
		if int(g) + 1 >= len(f.loca) {
			continue
		}
		a, b := int(f.loca[g]), int(f.loca[g + 1])
		if b <= a || b - a < 10 {
			continue
		}
		at := f.glyf_at + a
		if bei16(f.data, at) >= 0 {
			continue // simple glyph
		}
		// Composite: a run of component records, each a flags word, a glyph
		// index, the arguments whose size the flags give, and an optional
		// transform whose size the flags also give.
		k := at + 10
		for {
			if k + 4 > f.glyf_at + b {
				break
			}
			flags := be16(f.data, k)
			comp := be16(f.data, k + 2)
			k += 4
			k += (flags & 0x0001) != 0 ? 4 : 2 // ARG_1_AND_2_ARE_WORDS
			switch {
			case (flags & 0x0008) != 0:
				k += 2 // WE_HAVE_A_SCALE
			case (flags & 0x0040) != 0:
				k += 4 // X_AND_Y_SCALE
			case (flags & 0x0080) != 0:
				k += 8 // TWO_BY_TWO
			}
			if int(comp) < f.num_glyphs && !keep[comp] {
				keep[comp] = true
				append(&pending, comp)
			}
			if (flags & 0x0020) == 0 { 	// MORE_COMPONENTS
				break
			}
		}
	}
}

@(private = "file")
put_be16 :: proc(b: ^[dynamic]u8, v: u16) {
	append(b, u8(v >> 8), u8(v))
}

@(private = "file")
put_be32 :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

@(private = "file")
pad4 :: proc(b: ^[dynamic]u8) {
	for len(b^) % 4 != 0 {
		append(b, 0)
	}
}

// table_checksum is the sum of a table's bytes read as big-endian u32s, with
// the tail zero-padded. Readers verify these, and at least one PDF consumer
// in the wild rejects a /FontFile2 whose head checksum does not add up.
@(private = "file")
table_checksum :: proc(d: []u8) -> u32 {
	sum := u32(0)
	i := 0
	for ; i + 4 <= len(d); i += 4 {
		sum += u32(d[i]) << 24 | u32(d[i + 1]) << 16 | u32(d[i + 2]) << 8 | u32(d[i + 3])
	}
	if i < len(d) {
		w := u32(0)
		for k in 0 ..< 4 {
			w = w << 8 | u32(i + k < len(d) ? d[i + k] : 0)
		}
		sum += w
	}
	return sum
}

// Tables the subset carries. `glyf`, `loca`, `head`, `hhea`, `hmtx` and
// `maxp` are the minimum a CIDFontType2 needs; the three hinting programs
// ride along when the original has them, so the embedded face hints exactly
// as the screen one does.
@(private = "file")
SUBSET_TABLES := [?]string{"cvt ", "fpgm", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "prep"}

// ttf_subset builds a new font file containing only the glyphs in `keep`
// (plus glyph 0, always). Glyph ids are preserved — see the note at the top.
ttf_subset :: proc(f: ^TTF, keep: map[u16]bool, alloc := context.allocator) -> []u8 {
	kept := make(map[u16]bool, len(keep) + 4, context.temp_allocator)
	for g in keep {
		if int(g) < f.num_glyphs {
			kept[g] = true
		}
	}
	kept[0] = true // .notdef must survive
	ttf_expand_composites(f, &kept)

	// glyf and loca, rebuilt side by side.
	glyf := make([dynamic]u8, 0, 16384, context.temp_allocator)
	loca := make([dynamic]u8, 0, 4 * (f.num_glyphs + 1), context.temp_allocator)
	for g in 0 ..< f.num_glyphs {
		put_be32(&loca, u32(len(glyf)))
		if !kept[u16(g)] {
			continue
		}
		a, b := int(f.loca[g]), int(f.loca[g + 1])
		if b <= a {
			continue // an empty glyph, such as a space
		}
		lo := f.glyf_at + a
		hi := min(f.glyf_at + b, len(f.data))
		if hi > lo {
			append(&glyf, ..f.data[lo:hi])
		}
		pad4(&glyf)
	}
	put_be32(&loca, u32(len(glyf)))

	// head, with the loca format forced to long and the checksum cleared.
	head := make([dynamic]u8, 0, 54, context.temp_allocator)
	if at, length, has := ttf_table(f, "head"); has {
		append(&head, ..f.data[at:min(at + length, len(f.data))])
		for len(head) < 54 {
			append(&head, 0)
		}
		head[8], head[9], head[10], head[11] = 0, 0, 0, 0 // checkSumAdjustment
		head[50], head[51] = 0, 1 // indexToLocFormat = long
	}

	Part :: struct {
		tag:  string,
		data: []u8,
	}
	parts := make([dynamic]Part, 0, len(SUBSET_TABLES), context.temp_allocator)
	for name in SUBSET_TABLES {
		switch name {
		case "glyf":
			append(&parts, Part{name, glyf[:]})
		case "loca":
			append(&parts, Part{name, loca[:]})
		case "head":
			if len(head) > 0 {
				append(&parts, Part{name, head[:]})
			}
		case:
			if at, length, has := ttf_table(f, name); has && length > 0 && at + length <= len(f.data) {
				append(&parts, Part{name, f.data[at:at + length]})
			}
		}
	}
	// The directory must be sorted by tag; SUBSET_TABLES already is, but a
	// missing optional table must not leave a gap in the wrong place.
	slice.sort_by(parts[:], proc(a, b: Part) -> bool {return a.tag < b.tag})

	n := len(parts)
	out := make([dynamic]u8, 0, len(glyf) + 8192, alloc)
	put_be32(&out, 0x00010000)
	put_be16(&out, u16(n))
	// searchRange / entrySelector / rangeShift: the largest power of two not
	// exceeding n, times 16, and the remainder.
	pow, sel := 1, u16(0)
	for pow * 2 <= n {
		pow *= 2
		sel += 1
	}
	put_be16(&out, u16(pow * 16))
	put_be16(&out, sel)
	put_be16(&out, u16(n * 16 - pow * 16))

	// Reserve the records, then lay the tables out and fill the records in.
	dir := len(out)
	for _ in 0 ..< n {
		for _ in 0 ..< 16 {
			append(&out, 0)
		}
	}
	head_at := -1
	for part, i in parts {
		pad4(&out)
		at := len(out)
		append(&out, ..part.data)
		rec := dir + i * 16
		tg := tag_of(part.tag)
		out[rec + 0], out[rec + 1], out[rec + 2], out[rec + 3] =
			u8(tg >> 24), u8(tg >> 16), u8(tg >> 8), u8(tg)
		ck := table_checksum(part.data)
		out[rec + 4], out[rec + 5], out[rec + 6], out[rec + 7] =
			u8(ck >> 24), u8(ck >> 16), u8(ck >> 8), u8(ck)
		out[rec + 8], out[rec + 9], out[rec + 10], out[rec + 11] =
			u8(at >> 24), u8(at >> 16), u8(at >> 8), u8(at)
		l := len(part.data)
		out[rec + 12], out[rec + 13], out[rec + 14], out[rec + 15] =
			u8(l >> 24), u8(l >> 16), u8(l >> 8), u8(l)
		if part.tag == "head" {
			head_at = at
		}
	}
	pad4(&out)

	// head.checkSumAdjustment is 0xB1B0AFBA minus the whole file's checksum,
	// computed with the field itself zero — which it is, from above.
	if head_at >= 0 && head_at + 12 <= len(out) {
		adj := 0xb1b0afba - table_checksum(out[:])
		out[head_at + 8], out[head_at + 9], out[head_at + 10], out[head_at + 11] =
			u8(adj >> 24), u8(adj >> 16), u8(adj >> 8), u8(adj)
	}
	return out[:]
}
