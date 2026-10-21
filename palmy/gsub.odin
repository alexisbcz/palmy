package palmy

// ---------------------------------------------------------------------------
// GSUB: glyph substitution, as much of it as a colour emoji font needs.
//
// A colour emoji font draws a ZWJ sequence, a skin-tone variant, a flag or a
// keycap as one glyph of its own, and the only thing that says which glyph is
// the font's GSUB table. NotoColorEmoji 2.047 (the font every Linux box has)
// puts all of it under one feature, `ccmp`, as four lookups:
//
//	0  type 4, ligature    3,986 sequences: 👨 ZWJ 💻 -> man technologist,
//	                       👍 🏽 -> thumbs up: medium skin tone, 🇫 🇷 -> 🇫🇷,
//	                       1 ⃣ -> 1️⃣, 🏴 + tag letters + cancel tag -> 🏴󠁧󠁢󠁳󠁣󠁴󠁿
//	2  type 6, chain       a tag letter after 🏴 that no ligature took is deleted
//	   (format 2)          (through lookup 1, type 2 with an empty sequence)
//	3  type 4              🏴 + cancel tag that is left -> plain 🏴
//	4  type 5, context     two regional indicators that are not a flag become
//	   (format 2)          one "unknown flag" glyph (lookups 5 and 1)
//
// So the engine here does types 1 (single), 2 (multiple, including deletion),
// 4 (ligature), 5 and 6 in all three formats, and 7 (extension), which is the
// whole of what a substitution font is allowed to nest. Type 3 (alternate) and
// type 8 (reverse chaining) are never selected by the features asked for and
// are not implemented; a lookup of either type does nothing.
//
// What it is not is a text shaper. There is no GDEF, so LookupFlag's
// ignore-marks bits do nothing -- an emoji font has no marks to ignore -- and
// no script-specific feature ordering. The outline faces still go through
// stb_truetype without GSUB, and Arabic still goes through presentation forms
// (shape.odin explains why). This exists for the font that cannot be drawn
// correctly without it.
//
// Matching steps over default-ignorable code points the way HarfBuzz does: a
// glyph whose source is a variation selector or a joiner is matched if the rule
// names it and skipped otherwise. NotoColorEmoji's 3,986 ligatures name ZWJ but
// never U+FE0F, so "👩🏽‍⚕️" (woman, tone, ZWJ, staff of aesculapius, VS16)
// ligates with the VS16 stepped over and absorbed into the ligature.
// The tag characters are not skippable: they are the flag.
// ---------------------------------------------------------------------------

@(private)
Gsub :: struct {
	data:    []u8, // borrowed from the font
	lookups: int,  // the LookupList, absolute; 0 when the font has no GSUB
	active:  [dynamic]u16, // lookup indices of the requested features, ascending
}

// Gsub_Glyph is one glyph in the buffer substitution runs over, with the span
// of source bytes it stands for. Substitution keeps the spans a partition of
// the source: a ligature takes the union of its components' spans, and a
// deleted glyph's span is merged into a neighbour.
@(private)
Gsub_Glyph :: struct {
	gid:        u32,
	start, end: int,
	skip:       bool, // a default-ignorable source: matched if named, else stepped over
}

@(private)
GSUB_MAX_DEPTH :: 6 // nested context lookups
@(private)
GSUB_MAX_GROWTH :: 64 // glyphs a multiple substitution may add to one buffer
@(private)
GSUB_MAX_CONTEXT :: 64 // glyphs in one context rule's input

// gsub_init reads the table at `table` (absolute) and collects the lookups of
// the features named, for the DFLT script (or the first script, for a font
// that has no DFLT) and its default language system.
@(private)
gsub_init :: proc(g: ^Gsub, data: []u8, table: int, features: []string) -> bool {
	g.data = data
	g.lookups = 0
	clear(&g.active)
	if table <= 0 || table + 10 > len(data) {
		return false
	}
	d := data
	scripts := table + int(sfnt_u16(d, table + 4))
	feats := table + int(sfnt_u16(d, table + 6))
	g.lookups = table + int(sfnt_u16(d, table + 8))

	// The script: DFLT, else the first one listed.
	nscripts := int(sfnt_u16(d, scripts))
	script := 0
	for i in 0 ..< nscripts {
		rec := scripts + 2 + 6 * i
		if rec + 6 > len(d) {
			break
		}
		if string(d[rec:rec + 4]) == "DFLT" || script == 0 {
			script = scripts + int(sfnt_u16(d, rec + 4))
			if string(d[rec:rec + 4]) == "DFLT" {
				break
			}
		}
	}
	if script == 0 {
		return false
	}
	lang := 0
	if off := int(sfnt_u16(d, script)); off != 0 {
		lang = script + off
	} else if sfnt_u16(d, script + 2) > 0 {
		lang = script + int(sfnt_u16(d, script + 2 + 2 + 4))
	}
	if lang == 0 {
		return false
	}

	nfeat := int(sfnt_u16(d, feats))
	take :: proc(g: ^Gsub, d: []u8, feats, nfeat, fi: int, want: []string) {
		if fi < 0 || fi >= nfeat {
			return
		}
		rec := feats + 2 + 6 * fi
		if rec + 6 > len(d) {
			return
		}
		tag := string(d[rec:rec + 4])
		named := false
		for w in want {
			if w == tag {
				named = true
			}
		}
		if !named {
			return
		}
		feat := feats + int(sfnt_u16(d, rec + 4))
		n := int(sfnt_u16(d, feat + 2))
		for k in 0 ..< n {
			li := u16(sfnt_u16(d, feat + 4 + 2 * k))
			// Ascending and unique: lookups apply in LookupList order, which is
			// the order the font's author wrote them in, whichever feature
			// they belong to.
			at := len(g.active)
			for at > 0 && g.active[at - 1] > li {
				at -= 1
			}
			if at > 0 && g.active[at - 1] == li {
				continue
			}
			inject_at(&g.active, at, li)
		}
	}
	if req := int(sfnt_u16(d, lang + 2)); req != 0xffff {
		take(g, d, feats, nfeat, req, features)
	}
	nidx := int(sfnt_u16(d, lang + 4))
	for i in 0 ..< nidx {
		take(g, d, feats, nfeat, int(sfnt_u16(d, lang + 6 + 2 * i)), features)
	}
	return len(g.active) > 0
}

@(private)
gsub_destroy :: proc(g: ^Gsub) {
	delete(g.active)
	g^ = {}
}

// gsub_apply runs every active lookup over the buffer, in order, each one
// across the whole buffer before the next starts.
@(private)
gsub_apply :: proc(g: ^Gsub, buf: ^[dynamic]Gsub_Glyph) {
	if g.lookups == 0 || len(buf) == 0 {
		return
	}
	limit := len(buf) + GSUB_MAX_GROWTH
	for li in g.active {
		// A lookup that applied returns where to go on from, which is `i`
		// itself only when it deleted the glyph there; the buffer is then
		// shorter, so the walk still ends. The guard is for a hostile font
		// that would make it otherwise.
		i, steps := 0, 0
		for i < len(buf) && steps < 8 * limit {
			steps += 1
			if next, ok := gsub_lookup_at(g, int(li), buf, i, 0, limit); ok {
				i = next
			} else {
				i += 1
			}
		}
	}
}

// gsub_lookup_at applies one lookup at one position: the first of its
// subtables that matches there. It returns where the caller should continue.
@(private)
gsub_lookup_at :: proc(
	g: ^Gsub,
	li: int,
	buf: ^[dynamic]Gsub_Glyph,
	i: int,
	depth: int,
	limit: int,
) -> (
	next: int,
	ok: bool,
) {
	d := g.data
	if depth > GSUB_MAX_DEPTH || i < 0 || i >= len(buf) {
		return
	}
	if li < 0 || li >= int(sfnt_u16(d, g.lookups)) {
		return
	}
	lk := g.lookups + int(sfnt_u16(d, g.lookups + 2 + 2 * li))
	typ := sfnt_u16(d, lk)
	nsub := int(sfnt_u16(d, lk + 4))
	for s in 0 ..< nsub {
		st := lk + int(sfnt_u16(d, lk + 6 + 2 * s))
		t := typ
		if t == 7 {
			// Extension: the real type and a 32-bit offset to the subtable.
			t = sfnt_u16(d, st + 2)
			st = st + int(sfnt_u32(d, st + 4))
			if t == 7 {
				continue // an extension may not point at another
			}
		}
		if n, applied := gsub_subtable(g, t, st, buf, i, depth, limit); applied {
			return n, true
		}
	}
	return
}

@(private)
gsub_subtable :: proc(
	g: ^Gsub,
	typ: u32,
	st: int,
	buf: ^[dynamic]Gsub_Glyph,
	i: int,
	depth: int,
	limit: int,
) -> (
	next: int,
	ok: bool,
) {
	d := g.data
	gid := buf[i].gid
	format := sfnt_u16(d, st)

	switch typ {
	case 1: // single
		ci := gsub_coverage(d, st + int(sfnt_u16(d, st + 2)), gid)
		if ci < 0 {
			return
		}
		switch format {
		case 1:
			delta := u32(i32(i16(u16(sfnt_u16(d, st + 4)))))
			buf[i].gid = (gid + delta) & 0xffff
		case 2:
			if ci >= int(sfnt_u16(d, st + 4)) {
				return
			}
			buf[i].gid = sfnt_u16(d, st + 6 + 2 * ci)
		case:
			return
		}
		buf[i].skip = false
		return i + 1, true

	case 2: // multiple: one glyph becomes a sequence, possibly an empty one
		if format != 1 {
			return
		}
		ci := gsub_coverage(d, st + int(sfnt_u16(d, st + 2)), gid)
		if ci < 0 || ci >= int(sfnt_u16(d, st + 4)) {
			return
		}
		seq := st + int(sfnt_u16(d, st + 6 + 2 * ci))
		n := int(sfnt_u16(d, seq))
		if n == 0 {
			gsub_delete(buf, i)
			return i, true
		}
		if len(buf) + n - 1 > limit {
			return
		}
		src := buf[i]
		buf[i].gid = sfnt_u16(d, seq + 2)
		buf[i].skip = false
		for k in 1 ..< n {
			// Every glyph of the sequence came from the one source glyph. The
			// first keeps its span and the rest own nothing, so the spans still
			// partition the source.
			inject_at(buf, i + k, Gsub_Glyph{gid = sfnt_u16(d, seq + 2 + 2 * k), start = src.end, end = src.end})
		}
		return i + n, true

	case 4: // ligature
		if format != 1 {
			return
		}
		ci := gsub_coverage(d, st + int(sfnt_u16(d, st + 2)), gid)
		if ci < 0 || ci >= int(sfnt_u16(d, st + 4)) {
			return
		}
		set := st + int(sfnt_u16(d, st + 6 + 2 * ci))
		nlig := int(sfnt_u16(d, set))
		ligs: for l in 0 ..< nlig {
			lig := set + int(sfnt_u16(d, set + 2 + 2 * l))
			comps := int(sfnt_u16(d, lig + 2))
			if comps < 1 {
				continue
			}
			j := i
			for k in 1 ..< comps {
				want := sfnt_u16(d, lig + 4 + 2 * (k - 1))
				m, found := gsub_next(buf, j + 1, Gsub_Match{kind = .Glyph, value = want})
				if !found {
					continue ligs
				}
				j = m
			}
			// The ligature takes the components and every ignorable stepped
			// over between them: a VS16 inside "👩🏽‍⚕️" belongs to the person.
			buf[i].gid = sfnt_u16(d, lig)
			buf[i].skip = false
			buf[i].end = buf[j].end
			remove_range(buf, i + 1, j + 1)
			return i + 1, true
		}
		return

	case 5, 6:
		return gsub_context(g, typ == 6, format, st, buf, i, depth, limit)
	}
	return
}

// gsub_delete removes a glyph and gives its source bytes to a neighbour.
@(private)
gsub_delete :: proc(buf: ^[dynamic]Gsub_Glyph, i: int) {
	gone := buf[i]
	ordered_remove(buf, i)
	switch {
	case i > 0:
		buf[i - 1].end = max(buf[i - 1].end, gone.end)
	case len(buf) > 0:
		buf[0].start = min(buf[0].start, gone.start)
	}
}

// ---------------------------------------------------------------------------
// Coverage and class definitions
// ---------------------------------------------------------------------------

// gsub_coverage is the glyph's index in a coverage table, or -1.
@(private)
gsub_coverage :: proc(d: []u8, off: int, gid: u32) -> int {
	switch sfnt_u16(d, off) {
	case 1:
		n := int(sfnt_u16(d, off + 2))
		lo, hi := 0, n - 1
		for lo <= hi {
			mid := (lo + hi) / 2
			v := sfnt_u16(d, off + 4 + 2 * mid)
			switch {
			case gid < v:
				hi = mid - 1
			case gid > v:
				lo = mid + 1
			case:
				return mid
			}
		}
	case 2:
		n := int(sfnt_u16(d, off + 2))
		lo, hi := 0, n - 1
		for lo <= hi {
			mid := (lo + hi) / 2
			r := off + 4 + 6 * mid
			switch {
			case gid < sfnt_u16(d, r):
				hi = mid - 1
			case gid > sfnt_u16(d, r + 2):
				lo = mid + 1
			case:
				return int(sfnt_u16(d, r + 4) + gid - sfnt_u16(d, r))
			}
		}
	}
	return -1
}

// gsub_class is the glyph's class in a class definition table; 0 for a glyph
// it does not list, and for no table at all.
@(private)
gsub_class :: proc(d: []u8, off: int, gid: u32) -> u32 {
	if off <= 0 {
		return 0
	}
	switch sfnt_u16(d, off) {
	case 1:
		first := sfnt_u16(d, off + 2)
		n := sfnt_u16(d, off + 4)
		if gid >= first && gid - first < n {
			return sfnt_u16(d, off + 6 + 2 * int(gid - first))
		}
	case 2:
		n := int(sfnt_u16(d, off + 2))
		lo, hi := 0, n - 1
		for lo <= hi {
			mid := (lo + hi) / 2
			r := off + 4 + 6 * mid
			switch {
			case gid < sfnt_u16(d, r):
				hi = mid - 1
			case gid > sfnt_u16(d, r + 2):
				lo = mid + 1
			case:
				return sfnt_u16(d, r + 4)
			}
		}
	}
	return 0
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

// Gsub_Match is what one position of a rule asks for: a glyph id, a class in a
// class definition, or membership of a coverage table.
@(private)
Gsub_Match :: struct {
	kind:  enum u8 {
		Glyph,
		Class,
		Cover,
	},
	value: u32, // the glyph or the class
	table: int, // the class definition or the coverage table, absolute
}

@(private)
gsub_matches :: proc(d: []u8, m: Gsub_Match, gid: u32) -> bool {
	switch m.kind {
	case .Glyph:
		return gid == m.value
	case .Class:
		return gsub_class(d, m.table, gid) == m.value
	case .Cover:
		return gsub_coverage(d, m.table, gid) >= 0
	}
	return false
}

// gsub_next finds the next glyph from `from` that satisfies `m`, stepping over
// default-ignorables that do not.
@(private)
gsub_next :: proc(buf: ^[dynamic]Gsub_Glyph, from: int, m: Gsub_Match, d: []u8 = nil) -> (int, bool) {
	for j := from; j < len(buf); j += 1 {
		ok := m.kind == .Glyph ? buf[j].gid == m.value : gsub_matches(d, m, buf[j].gid)
		if ok {
			return j, true
		}
		if !buf[j].skip {
			return -1, false
		}
	}
	return -1, false
}

// gsub_prev is gsub_next backwards, for backtrack sequences.
@(private)
gsub_prev :: proc(buf: ^[dynamic]Gsub_Glyph, from: int, m: Gsub_Match, d: []u8) -> (int, bool) {
	for j := from; j >= 0; j -= 1 {
		if gsub_matches(d, m, buf[j].gid) {
			return j, true
		}
		if !buf[j].skip {
			return -1, false
		}
	}
	return -1, false
}

// Gsub_Seq is one of a rule's three sequences (backtrack, input, lookahead)
// as stored: `count` u16 values at `arr`, each a glyph, a class against
// `classes`, or a coverage offset relative to `base`.
@(private)
Gsub_Seq :: struct {
	arr:     int,
	count:   int,
	kind:    int, // 1 glyphs, 2 classes, 3 coverages
	classes: int,
	base:    int,
}

@(private)
gsub_seq_at :: proc(d: []u8, s: Gsub_Seq, k: int) -> Gsub_Match {
	v := sfnt_u16(d, s.arr + 2 * k)
	switch s.kind {
	case 1:
		return {kind = .Glyph, value = v}
	case 2:
		return {kind = .Class, value = v, table = s.classes}
	}
	return {kind = .Cover, table = s.base + int(v)}
}

// gsub_context tries every rule of a (chained) context subtable at `i` and
// applies the first that matches.
@(private)
gsub_context :: proc(
	g: ^Gsub,
	chain: bool,
	format: u32,
	st: int,
	buf: ^[dynamic]Gsub_Glyph,
	i: int,
	depth: int,
	limit: int,
) -> (
	next: int,
	ok: bool,
) {
	d := g.data
	gid := buf[i].gid

	switch format {
	case 1, 2:
		ci := gsub_coverage(d, st + int(sfnt_u16(d, st + 2)), gid)
		if ci < 0 {
			return
		}
		// Format 1 picks a rule set by coverage index and compares glyph ids;
		// format 2 picks it by the first glyph's input class and compares
		// classes, each sequence against its own class definition.
		back_cd, in_cd, ahead_cd := 0, 0, 0
		sets := st + 6
		set_count := int(sfnt_u16(d, st + 4))
		pick := ci
		if format == 2 {
			if chain {
				back_cd = gsub_off(d, st, st + 4)
				in_cd = gsub_off(d, st, st + 6)
				ahead_cd = gsub_off(d, st, st + 8)
				set_count = int(sfnt_u16(d, st + 10))
				sets = st + 12
			} else {
				in_cd = gsub_off(d, st, st + 4)
				set_count = int(sfnt_u16(d, st + 6))
				sets = st + 8
			}
			pick = int(gsub_class(d, in_cd, gid))
		}
		if pick >= set_count {
			return
		}
		set_off := int(sfnt_u16(d, sets + 2 * pick))
		if set_off == 0 {
			return
		}
		set := st + set_off
		kind := format == 1 ? 1 : 2
		nrules := int(sfnt_u16(d, set))
		for r in 0 ..< nrules {
			rule := set + int(sfnt_u16(d, set + 2 + 2 * r))
			back, input, ahead: Gsub_Seq
			recs, nrecs: int
			if chain {
				p := rule
				back = {arr = p + 2, count = int(sfnt_u16(d, p)), kind = kind, classes = back_cd}
				p = back.arr + 2 * back.count
				input = {arr = p + 2, count = int(sfnt_u16(d, p)), kind = kind, classes = in_cd}
				p = input.arr + 2 * max(input.count - 1, 0)
				ahead = {arr = p + 2, count = int(sfnt_u16(d, p)), kind = kind, classes = ahead_cd}
				p = ahead.arr + 2 * ahead.count
				nrecs = int(sfnt_u16(d, p))
				recs = p + 2
			} else {
				input = {arr = rule + 4, count = int(sfnt_u16(d, rule)), kind = kind, classes = in_cd}
				nrecs = int(sfnt_u16(d, rule + 2))
				recs = input.arr + 2 * max(input.count - 1, 0)
			}
			// Formats 1 and 2 leave the first input glyph out: the coverage
			// (or the class the set was picked by) already matched it.
			if n, applied := gsub_rule(g, buf, i, back, input, true, ahead, recs, nrecs, depth, limit);
			   applied {
				return n, true
			}
		}
		return

	case 3:
		back, input, ahead: Gsub_Seq
		recs, nrecs: int
		if chain {
			p := st + 2
			back = {arr = p + 2, count = int(sfnt_u16(d, p)), kind = 3, base = st}
			p = back.arr + 2 * back.count
			input = {arr = p + 2, count = int(sfnt_u16(d, p)), kind = 3, base = st}
			p = input.arr + 2 * input.count
			ahead = {arr = p + 2, count = int(sfnt_u16(d, p)), kind = 3, base = st}
			p = ahead.arr + 2 * ahead.count
			nrecs = int(sfnt_u16(d, p))
			recs = p + 2
		} else {
			input = {arr = st + 6, count = int(sfnt_u16(d, st + 2)), kind = 3, base = st}
			nrecs = int(sfnt_u16(d, st + 4))
			recs = input.arr + 2 * input.count
		}
		if input.count < 1 || !gsub_matches(d, gsub_seq_at(d, input, 0), gid) {
			return
		}
		return gsub_rule(g, buf, i, back, input, false, ahead, recs, nrecs, depth, limit)
	}
	return
}

// gsub_off reads a 16-bit offset relative to `base`, keeping 0 as "absent".
@(private)
gsub_off :: proc(d: []u8, base, at: int) -> int {
	o := int(sfnt_u16(d, at))
	return o == 0 ? 0 : base + o
}

// gsub_rule matches one rule's three sequences around `i` and, when they all
// match, applies its nested lookups at the input positions they name.
@(private)
gsub_rule :: proc(
	g: ^Gsub,
	buf: ^[dynamic]Gsub_Glyph,
	i: int,
	back, input: Gsub_Seq,
	first_implied: bool,
	ahead: Gsub_Seq,
	recs, nrecs: int,
	depth: int,
	limit: int,
) -> (
	next: int,
	ok: bool,
) {
	d := g.data
	if input.count < 1 || input.count > GSUB_MAX_CONTEXT {
		return
	}
	pos: [GSUB_MAX_CONTEXT]int
	pos[0] = i
	j := i
	for k in 1 ..< input.count {
		m := gsub_seq_at(d, input, first_implied ? k - 1 : k)
		found: bool
		if j, found = gsub_next(buf, j + 1, m, d); !found {
			return
		}
		pos[k] = j
	}
	end := j
	b := i - 1
	for k in 0 ..< back.count {
		found: bool
		if b, found = gsub_prev(buf, b, gsub_seq_at(d, back, k), d); !found {
			return
		}
		b -= 1
	}
	a := end + 1
	for k in 0 ..< ahead.count {
		found: bool
		if a, found = gsub_next(buf, a, gsub_seq_at(d, ahead, k), d); !found {
			return
		}
		a += 1
	}

	// Each record applies one lookup at one input position. A nested
	// substitution can change the buffer's length (a deletion, a ligature), so
	// the positions after it move by the same amount.
	for r in 0 ..< nrecs {
		seq := int(sfnt_u16(d, recs + 4 * r))
		li := int(sfnt_u16(d, recs + 4 * r + 2))
		if seq >= input.count {
			continue
		}
		at := pos[seq]
		if at < 0 || at >= len(buf) {
			continue
		}
		before := len(buf)
		gsub_lookup_at(g, li, buf, at, depth + 1, limit)
		delta := len(buf) - before
		if delta != 0 {
			for k in seq + 1 ..< input.count {
				pos[k] += delta
			}
			end += delta
		}
	}
	return clamp(end + 1, i, len(buf)), true
}
