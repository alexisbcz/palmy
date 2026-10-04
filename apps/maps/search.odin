package main

// Search: find a place or a street by name.
//
// The index is built once, when the data loads: every named feature, with its
// name folded to lower case and the offsets of its word starts precomputed.
// That is the only preparation; a query then scans the whole index. A city
// extract has a few thousand distinct names, a scan costs under a millisecond,
// and a trie would buy nothing except the inability to do the fuzzy pass.
//
// Four kinds of match, scored in this order, because that is the order a person
// means them in:
//
//   exact          "harbour avenue"  ->  Harbour Avenue
//   prefix         "harb"            ->  Harbour Avenue
//   word prefix    "aven"            ->  Harbour Avenue
//   substring      "bour av"         ->  Harbour Avenue
//   fuzzy          "hbav"            ->  Harbour Avenue
//
// The fuzzy pass is a subsequence match scored by how tightly the query's
// characters sit together and whether they landed on word boundaries, which is
// the scoring every editor's fuzzy finder uses and the reason "hbav" beats
// "harbour" for a typo rather than returning everything.
//
// Features with the same name — a street split into several ways, which is the
// normal case in OSM data — are collapsed into one result covering the union of
// their extents, so searching for a road does not return it eleven times.

import "core:math"
import "core:strings"

Index_Entry :: struct {
	name:   string, // the original, for display
	fold:   string, // lower case, owned by the index
	feat:   i32,
	class:  Class,
	rank:   f32,
	bbox:   Bbox,
	// Byte offsets of word starts in `fold`, up to eight.
	words:  [8]u8,
	nwords: u8,
}

Search_Index :: struct {
	entries: [dynamic]Index_Entry,
	folded:  strings.Builder,
	// name -> entry index, for collapsing duplicates.
	by_name: map[string]int,
}

Hit :: struct {
	entry: int,
	score: f32,
}

index_destroy :: proc(ix: ^Search_Index) {
	delete(ix.entries)
	strings.builder_destroy(&ix.folded)
	delete(ix.by_name)
	ix^ = {}
}

// index_build walks the map once. The folded names all live in one builder, so
// the offsets are recorded first and resolved after the builder has stopped
// growing — the same two-phase trick the Map's string arena uses.
index_build :: proc(ix: ^Search_Index, m: ^Map) {
	index_destroy(ix)
	ix.entries = make([dynamic]Index_Entry)
	ix.folded = strings.builder_make()
	ix.by_name = make(map[string]int)

	offs := make([dynamic][2]int, context.temp_allocator)

	for f, fi in m.features {
		if f.name == "" {
			continue
		}
		if existing, ok := ix.by_name[f.name]; ok {
			// Same name, another way: widen the extent and keep the better
			// ranked feature as the one the view flies to.
			e := &ix.entries[existing]
			e.bbox = bbox_union(e.bbox, f.bbox)
			if f.rank > e.rank {
				e.rank = f.rank
				e.feat = i32(fi)
				e.class = f.class
			}
			continue
		}
		off := strings.builder_len(ix.folded)
		for r in f.name {
			strings.write_rune(&ix.folded, fold_rune(r))
		}
		n := strings.builder_len(ix.folded) - off

		e := Index_Entry {
			name  = f.name,
			feat  = i32(fi),
			class = f.class,
			rank  = f.rank,
			bbox  = f.bbox,
		}
		append(&ix.entries, e)
		append(&offs, [2]int{off, n})
		ix.by_name[f.name] = len(ix.entries) - 1
	}

	all := strings.to_string(ix.folded)
	for &e, i in ix.entries {
		e.fold = all[offs[i][0]:][:offs[i][1]]
		// Word starts.
		e.nwords = 0
		prev_sep := true
		for j in 0 ..< len(e.fold) {
			c := e.fold[j]
			sep := c == ' ' || c == '-' || c == '\'' || c == '.' || c == '/' || c == '('
			if !sep && prev_sep && e.nwords < 8 {
				e.words[e.nwords] = u8(min(j, 255))
				e.nwords += 1
			}
			prev_sep = sep
		}
	}
}

index_count :: proc(ix: ^Search_Index) -> int {
	return len(ix.entries)
}

// fold_rune lower-cases ASCII and strips the accents this project's data can
// contain. Anything else passes through: a correct Unicode case fold needs
// tables palmy does not ship, and folding only the Latin range is honest about
// that rather than silently mangling Greek.
fold_rune :: proc(r: rune) -> rune {
	if r >= 'A' && r <= 'Z' {
		return r + 32
	}
	switch r {
	case 'À', 'Á', 'Â', 'Ã', 'Ä', 'Å', 'à', 'á', 'â', 'ã', 'ä', 'å':
		return 'a'
	case 'È', 'É', 'Ê', 'Ë', 'è', 'é', 'ê', 'ë':
		return 'e'
	case 'Ì', 'Í', 'Î', 'Ï', 'ì', 'í', 'î', 'ï':
		return 'i'
	case 'Ò', 'Ó', 'Ô', 'Õ', 'Ö', 'ò', 'ó', 'ô', 'õ', 'ö':
		return 'o'
	case 'Ù', 'Ú', 'Û', 'Ü', 'ù', 'ú', 'û', 'ü':
		return 'u'
	case 'Ç', 'ç':
		return 'c'
	case 'Ñ', 'ñ':
		return 'n'
	}
	return r
}

fold_string :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for r in s {
		strings.write_rune(&sb, fold_rune(r))
	}
	return strings.to_string(sb)
}

// search runs a query and fills `out` with the best hits, best first.
search :: proc(ix: ^Search_Index, query: string, out: ^[dynamic]Hit, limit := 40) {
	clear(out)
	q := strings.trim_space(fold_string(query))
	if q == "" {
		return
	}
	for &e, i in ix.entries {
		s := score_entry(&e, q)
		if s <= 0 {
			continue
		}
		append(out, Hit{entry = i, score = s})
	}
	// Partial selection sort: only `limit` results are ever shown, so there is
	// no reason to order the tail.
	n := min(limit, len(out))
	for i in 0 ..< n {
		best := i
		for j in i + 1 ..< len(out) {
			if out[j].score > out[best].score {
				best = j
			} else if out[j].score == out[best].score && out[j].entry < out[best].entry {
				// A stable tie-break, so the same query always gives the same
				// order — which the self-test depends on.
				best = j
			}
		}
		out[i], out[best] = out[best], out[i]
	}
	if len(out) > n {
		resize(out, n)
	}
}

// score_entry scores one name against a folded query. Zero means no match.
score_entry :: proc(e: ^Index_Entry, q: string) -> f32 {
	name := e.fold
	if len(q) == 0 || len(name) == 0 {
		return 0
	}
	base := f32(0)

	switch {
	case name == q:
		base = 1000
	case strings.has_prefix(name, q):
		base = 820 + 60 * f32(len(q)) / f32(len(name))
	case word_prefix(e, q):
		base = 660
	case strings.contains(name, q):
		// Earlier in the name is a better match.
		at := strings.index(name, q)
		base = 520 - 2 * f32(min(at, 40))
	case:
		f := fuzzy_score(e, q)
		if f <= 0 {
			return 0
		}
		base = 120 + f
	}

	// Importance, then brevity. A query that matches both "Harbour Avenue" and
	// "Harbour Avenue Car Park Entrance" means the shorter one.
	base += e.rank * 90
	base -= f32(min(len(name), 60)) * 0.4
	return base
}

@(private = "file")
word_prefix :: proc(e: ^Index_Entry, q: string) -> bool {
	for k in 0 ..< int(e.nwords) {
		at := int(e.words[k])
		if at < len(e.fold) && strings.has_prefix(e.fold[at:], q) {
			return true
		}
	}
	return false
}

// fuzzy_score is a subsequence match. Every character of the query must appear
// in order; the score rewards consecutive hits and hits on a word boundary, and
// penalises the gaps in between. Returns 0 when the query is not a subsequence.
fuzzy_score :: proc(e: ^Index_Entry, q: string) -> f32 {
	name := e.fold
	if len(q) > len(name) {
		return 0
	}
	is_word_start :: proc(e: ^Index_Entry, at: int) -> bool {
		for k in 0 ..< int(e.nwords) {
			if int(e.words[k]) == at {
				return true
			}
		}
		return false
	}

	score := f32(0)
	ni := 0
	prev_hit := -2
	for qi in 0 ..< len(q) {
		c := q[qi]
		found := -1
		for j in ni ..< len(name) {
			if name[j] == c {
				found = j
				break
			}
		}
		if found < 0 {
			return 0
		}
		if found == prev_hit + 1 {
			score += 14 // adjacent, which is what a real prefix looks like
		} else {
			gap := found - prev_hit - 1
			score -= f32(min(gap, 12)) * 1.2
		}
		if is_word_start(e, found) {
			score += 11
		}
		prev_hit = found
		ni = found + 1
	}
	// A query that covers most of the name is a better match than one that
	// picks eight letters out of forty.
	score += 40 * f32(len(q)) / f32(len(name))
	return math.max(score, 1)
}

// class_word is the human name of a class, shown beside a search result.
class_word :: proc(c: Class) -> string {
	switch c {
	case .City:
		return "City"
	case .Town:
		return "Town"
	case .Village:
		return "Village"
	case .Suburb:
		return "Neighbourhood"
	case .Poi:
		return "Place"
	case .Motorway:
		return "Motorway"
	case .Trunk:
		return "Trunk road"
	case .Primary:
		return "Primary road"
	case .Secondary:
		return "Secondary road"
	case .Tertiary:
		return "Street"
	case .Residential_Road:
		return "Residential street"
	case .Service:
		return "Service road"
	case .Path:
		return "Footpath"
	case .Rail:
		return "Railway"
	case .River:
		return "River"
	case .Water, .Ocean:
		return "Water"
	case .Park:
		return "Park"
	case .Forest:
		return "Woodland"
	case .Grass:
		return "Green space"
	case .Wetland:
		return "Wetland"
	case .Sand:
		return "Beach"
	case .Pitch:
		return "Sports ground"
	case .Building:
		return "Building"
	case .Landuse:
		return "Area"
	case .Unknown:
		return "Feature"
	}
	return "Feature"
}
