// Collaborative editing: the document model mapped onto the CRDT
// (cloud/collab/crdt), both ways.
//
// The editor keeps its own model — paragraphs of styled runs, tables of
// cells, pictures — and every command keeps working on it unchanged. This
// file is the binding between that model and the shared one:
//
//   * **local → shared** (`collab_sync`): after a frame's edits, the changed
//     container is compared with what the CRDT holds — a prefix/suffix diff
//     over its bytes, anchored at the caret so typing inside a run of equal
//     letters lands where the caret was — and the difference is written as
//     CRDT operations: inserts, deletes, Peritext marks for every character
//     style that differs, and registers for every paragraph property that
//     differs. Tables recurse: rows and columns are CRDT lists, each cell is
//     its own text container.
//   * **shared → local** (`collab_materialise`): after remote updates, the
//     whole model is rebuilt from the CRDT, and the caret and selection are
//     carried across as sticky positions (the element they sat after), so a
//     collaborator typing above you does not move your caret.
//
// The flattening, per container (the body, or one table cell):
//
//	para₀ bytes  '\n'  para₁ bytes  '\n' … paraₙ bytes
//
// A table or picture paragraph is one embed element. A paragraph's
// properties are registers on the element that ends it (its newline), or on
// "<container>$" for the last paragraph, so splitting and merging paragraphs
// moves properties exactly the way the newline moves.
//
// Keys (shared with the server's role checks, cloud/docs/office.md):
//
//	b                       the body text
//	c/<tbl>/<row>/<col>     a table cell's text
//	r/<tbl>  k/<tbl>        a table's rows and columns (one element each)
//	t/<tbl>                 table flags: h (header), bd (borders), and
//	                        m:<row>:<col> per merged cell: "<last row> <last col>"
//	w/<tbl>/<col>           a column's width
//	i/<img>                 a picture's scale
//	p/<elem> | p/<cont>$    a paragraph's properties
//	cmt/<id>                a comment thread (text, author, resolved)
//	cr/<id>                 its replies, one embed each
//	marks: b i u m sz c (style), cm:<id> (comment range), si sd (suggestions)
package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import client "../../cloud/collab/client"
import crdt "../../cloud/collab/crdt"

EMBED_BYTE :: u8(0xff) // never valid UTF-8, so never confused with text

Deco_Kind :: enum u8 {
	Comment,
	Comment_Active,
	Sugg_Ins,
	Sugg_Del,
}

// Deco is something drawn over a range of one block: a comment's
// highlight, a suggested insertion or deletion.
Deco :: struct {
	blk:   Blk,
	from:  int,
	to:    int,
	kind:  Deco_Kind,
	color: u32,
	id:    string, // comment id, or the suggesting handle
}

Comment_View :: struct {
	id:       string,
	text:     string,
	author:   string, // handle
	name:     string,
	color:    string,
	at:       i64,
	resolved: bool,
	quote:    string, // the text the range covers now
	anchor:   Pos, // where the range starts, for jumping and ordering
	alive:    bool, // the range still covers something
	replies:  [dynamic]Reply_View,
}

Reply_View :: struct {
	author: string,
	name:   string,
	color:  string,
	text:   string,
	at:     i64,
}

Table_Axes :: struct {
	rows: [dynamic]crdt.ID,
	cols: [dynamic]crdt.ID,
}

Collab :: struct {
	on:        bool,
	sess:      ^client.Session, // nil in tests: the CRDT is driven directly
	doc:       ^crdt.Doc,
	handle:    string, // this window's identity handle, for suggestions
	name:      string,
	color:     string,
	tables:    map[^Table]crdt.ID,
	images:    map[^Doc_Image]crdt.ID,
	axes:      map[crdt.ID]Table_Axes,
	img_cache: map[crdt.ID]Doc_Image, // decoded pictures, so a rebuild does not re-decode

	pending:   bool, // the model changed this frame
	tag:       Edit_Kind,
	hint:      int, // flat offset of the caret before the edit, -1 unknown
	hint_key:  string,
	caret_before: int,

	suggest:   bool, // suggestion mode: edits become proposals
	decos:     [dynamic]Deco,
	comments:  [dynamic]Comment_View,
	active_comment: string,
	show_comments: bool,
	panel:     Collab_Panel,
	note:      string, // the last thing worth telling the person
	materialised: int, // how many times the model was rebuilt (tests, status)
	saved:        bool,
	saved_caret:  Sticky_Pos,
	saved_anchor: Sticky_Pos,
}

Collab_Panel :: enum u8 {
	None,
	Comments,
	History,
	Share,
}

idkey :: proc(id: crdt.ID, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%x.%d", id.agent, id.seq, allocator = allocator)
}

parse_idkey :: proc(s: string) -> (crdt.ID, bool) {
	dot := strings.index_byte(s, '.')
	if dot <= 0 {
		return {}, false
	}
	a, ok1 := strconv.parse_u64_of_base(s[:dot], 16)
	q, ok2 := strconv.parse_u64_of_base(s[dot + 1:], 10)
	return crdt.ID{a, q}, ok1 && ok2
}

cell_key :: proc(tbl, row, col: crdt.ID, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("c/%s/%s/%s", idkey(tbl), idkey(row), idkey(col), allocator = allocator)
}

// ---------------------------------------------------------------------------
// Character styles <-> marks
// ---------------------------------------------------------------------------

STYLE_ATTRS := [?]string{"b", "i", "u", "m", "sz", "c"}

style_attr_value :: proc(cs: Char_Style, attr: string) -> string {
	switch attr {
	case "b":
		return cs.bold ? "1" : ""
	case "i":
		return cs.italic ? "1" : ""
	case "u":
		return cs.underline ? "1" : ""
	case "m":
		return cs.mono ? "1" : ""
	case "sz":
		return cs.size != 0 ? fmt.tprintf("%.2f", cs.size) : ""
	case "c":
		return cs.color != 0 ? fmt.tprintf("%08x", cs.color) : ""
	}
	return ""
}

style_from_attrs :: proc(attrs: []crdt.Attr) -> Char_Style {
	cs: Char_Style
	for a in attrs {
		v := string(a.value)
		switch a.name {
		case "b":
			cs.bold = v == "1"
		case "i":
			cs.italic = v == "1"
		case "u":
			cs.underline = v == "1"
		case "m":
			cs.mono = v == "1"
		case "sz":
			f, _ := strconv.parse_f32(v)
			cs.size = f
		case "c":
			n, _ := strconv.parse_u64_of_base(v, 16)
			cs.color = u32(n)
		}
	}
	return cs
}

// ---------------------------------------------------------------------------
// Paragraph properties <-> registers
// ---------------------------------------------------------------------------

PARA_FIELDS := [?]string{"k", "al", "ls", "d", "bf", "af", "pb"}

para_field_value :: proc(pa: ^Paragraph, f: string) -> string {
	switch f {
	case "k":
		if !text_kind(pa.kind) || pa.kind == .Body {return ""}
		return kind_name(pa.kind)
	case "al":
		return pa.align == .Left ? "" : align_name(pa.align)
	case "ls":
		return pa.list == .None ? "" : list_name(pa.list)
	case "d":
		return pa.depth == 0 ? "" : fmt.tprintf("%d", pa.depth)
	case "bf":
		return pa.before == 0 ? "" : fmt.tprintf("%.2f", pa.before)
	case "af":
		return pa.after == 0 ? "" : fmt.tprintf("%.2f", pa.after)
	case "pb":
		return pa.break_before ? "1" : ""
	}
	return ""
}

para_apply_fields :: proc(pa: ^Paragraph, d: ^crdt.Doc, owner: string) {
	if text_kind(pa.kind) {
		if k := crdt.reg_str(d, owner, "k"); k != "" {
			pa.kind = kind_from_name(k)
			if !text_kind(pa.kind) {pa.kind = .Body}
		}
	}
	if v := crdt.reg_str(d, owner, "al"); v != "" {pa.align = align_from_name(v)}
	if v := crdt.reg_str(d, owner, "ls"); v != "" {pa.list = list_from_name(v)}
	if v := crdt.reg_str(d, owner, "d"); v != "" {pa.depth, _ = strconv.parse_int(v)}
	if v := crdt.reg_str(d, owner, "bf"); v != "" {pa.before, _ = strconv.parse_f32(v)}
	if v := crdt.reg_str(d, owner, "af"); v != "" {pa.after, _ = strconv.parse_f32(v)}
	pa.break_before = crdt.reg_str(d, owner, "pb") == "1"
}

// ---------------------------------------------------------------------------
// Flat views of a container
// ---------------------------------------------------------------------------

// Shared is what the CRDT holds for one container, flattened.
Shared :: struct {
	bytes: [dynamic]u8,
	style: [dynamic]Char_Style,
	si:    [dynamic]string, // suggested insertion by, per byte ("" none)
	sd:    [dynamic]string, // suggested deletion by
	ids:   [dynamic]crdt.ID, // the element at each offset
	emb:   map[int][]u8, // offset -> embed payload
}

read_shared :: proc(d: ^crdt.Doc, key: string) -> Shared {
	context.allocator = context.temp_allocator
	out: Shared
	out.emb = make(map[int][]u8)
	sp := crdt.read_spans(d, key)
	for s in sp.spans {
		attrs := sp.attrs[s.attrs]
		cs := style_from_attrs(attrs)
		si := ""
		if v, ok := crdt.attr_get(attrs, "si"); ok && string(v) != "+" {
			si = string(v)
		} else if !ok && s.flags & crdt.FLAG_SUGGEST != 0 {
			si = "?"
		}
		sd := ""
		if v, ok := crdt.attr_get(attrs, "sd"); ok {
			sd = string(v)
		}
		switch s.kind {
		case .Text:
			for i in 0 ..< len(s.content) {
				append(&out.bytes, s.content[i])
				append(&out.style, cs)
				append(&out.si, si)
				append(&out.sd, sd)
				append(&out.ids, crdt.ID{s.first.agent, s.first.seq + u64(i)})
			}
		case .Embed:
			out.emb[len(out.bytes)] = s.content
			append(&out.bytes, EMBED_BYTE)
			append(&out.style, Char_Style{})
			append(&out.si, si)
			append(&out.sd, sd)
			append(&out.ids, s.first)
		case .Virtual:
		}
	}
	return out
}

// Local is the app's model of one container, flattened the same way.
Local :: struct {
	bytes: [dynamic]u8,
	style: [dynamic]Char_Style,
	obj:   map[int]rawptr, // offset -> ^Table or ^Doc_Image
	tbl:   map[int]bool, // offset -> the embed there is a table
	paras: []Paragraph,
	start: [dynamic]int, // each paragraph's first offset
}

read_local :: proc(paras: []Paragraph) -> Local {
	context.allocator = context.temp_allocator
	out: Local
	out.obj = make(map[int]rawptr)
	out.tbl = make(map[int]bool)
	out.paras = paras
	for i in 0 ..< len(paras) {
		pa := &paras[i]
		if i > 0 {
			append(&out.bytes, '\n')
			append(&out.style, Char_Style{})
		}
		append(&out.start, len(out.bytes))
		switch {
		case pa.kind == .Table && pa.table != nil:
			out.obj[len(out.bytes)] = pa.table
			out.tbl[len(out.bytes)] = true
			append(&out.bytes, EMBED_BYTE)
			append(&out.style, Char_Style{})
		case pa.kind == .Image && pa.img != nil:
			out.obj[len(out.bytes)] = pa.img
			append(&out.bytes, EMBED_BYTE)
			append(&out.style, Char_Style{})
		case:
			for &r in pa.runs {
				for b in r.text {
					append(&out.bytes, b)
					append(&out.style, r.style)
				}
			}
		}
	}
	return out
}

// embed_id is the CRDT identity of a table or picture the app holds.
embed_id :: proc(cb: ^Collab, obj: rawptr) -> crdt.ID {
	if id, ok := cb.tables[(^Table)(obj)]; ok {return id}
	if id, ok := cb.images[(^Doc_Image)(obj)]; ok {return id}
	return {}
}

// ---------------------------------------------------------------------------
// Local -> shared
// ---------------------------------------------------------------------------

// sync_container writes the difference between `paras` and the CRDT's view of
// container `key`. `hint` is the flat offset where the edit happened, or -1.
sync_container :: proc(cb: ^Collab, key: string, paras: []Paragraph, hint := -1) -> (changed: bool) {
	d := cb.doc
	sh := read_shared(d, key)
	lo := read_local(paras)
	m := len(lo.bytes)

	// Paragraph alignment first: paragraphs equal from both ends are left
	// alone. When the middle has the same number of paragraphs on both sides
	// (a restyle, a replace-all, typing in one paragraph) each pair is
	// diffed on its own, back to front so earlier offsets stay valid; this
	// keeps the identity — and so the comments and cursors — of every
	// character the edit did not touch. Otherwise the middle is one region.
	sp := shared_paras(&sh)
	np, nl := len(sp) - 1, len(lo.start)
	ppre := 0
	for ppre < np && ppre < nl && para_same(cb, &sh, &lo, sp[:], ppre, ppre) {ppre += 1}
	psuf := 0
	for psuf < np - ppre && psuf < nl - ppre && para_same(cb, &sh, &lo, sp[:], np - 1 - psuf, nl - 1 - psuf) {psuf += 1}
	if np - ppre - psuf == nl - ppre - psuf {
		for k := np - psuf - 1; k >= ppre; k -= 1 {
			s0, s1 := sp[k], sp[k + 1] - 1
			l0 := lo.start[k]
			l1 := k + 1 < nl ? lo.start[k + 1] - 1 : m
			if replace_region(cb, key, &sh, &lo, s0, s1, l0, l1, hint) {changed = true}
		}
	} else {
		// One region over the middle paragraphs, with the separators that
		// tie them to their neighbours. When one side has no paragraph left
		// at the prefix boundary, the region starts at the separator that
		// ends the last common paragraph, so a paragraph added or removed at
		// the end carries its newline with it.
		s0, l0, s1, l1: int
		if ppre < np && ppre < nl {
			s0, l0 = sp[ppre], lo.start[ppre]
		} else {
			s0 = ppre < np ? sp[ppre] - 1 : len(sh.bytes)
			l0 = ppre < nl ? lo.start[ppre] - 1 : m
		}
		if psuf > 0 {
			s1, l1 = sp[np - psuf], lo.start[nl - psuf]
		} else {
			s1, l1 = len(sh.bytes), m
		}
		if replace_region(cb, key, &sh, &lo, s0, s1, l0, l1, hint) {changed = true}
	}
	if changed {
		sh = read_shared(d, key)
	}
	return sync_rest(cb, key, paras, &sh, &lo) || changed
}

// shared_paras lists each paragraph's start offset in a shared flat, plus a
// final entry one past the end (so paragraph k is [sp[k], sp[k+1]-1)).
shared_paras :: proc(sh: ^Shared) -> [dynamic]int {
	out := make([dynamic]int, 0, 16, context.temp_allocator)
	append(&out, 0)
	for b, i in sh.bytes {
		if b == '\n' {append(&out, i + 1)}
	}
	append(&out, len(sh.bytes) + 1)
	return out
}

flat_same :: proc(cb: ^Collab, sh: ^Shared, lo: ^Local, i, j: int) -> bool {
	if sh.bytes[i] != lo.bytes[j] {return false}
	if sh.bytes[i] != EMBED_BYTE {return true}
	obj, ok := lo.obj[j]
	return ok && embed_id(cb, obj) == sh.ids[i]
}

para_same :: proc(cb: ^Collab, sh: ^Shared, lo: ^Local, sp: []int, ps, pl: int) -> bool {
	s0, s1 := sp[ps], sp[ps + 1] - 1
	l0 := lo.start[pl]
	l1 := pl + 1 < len(lo.start) ? lo.start[pl + 1] - 1 : len(lo.bytes)
	if s1 - s0 != l1 - l0 {return false}
	for k in 0 ..< s1 - s0 {
		if !flat_same(cb, sh, lo, s0 + k, l0 + k) {return false}
	}
	return true
}

// replace_region turns shared[s0:s1] into local[l0:l1] with the fewest
// operations a prefix/suffix comparison finds.
replace_region :: proc(cb: ^Collab, key: string, sh: ^Shared, lo: ^Local, s0, s1, l0, l1: int, hint: int) -> bool {
	d := cb.doc
	n := s1 - s0
	m := l1 - l0
	pre := 0
	for pre < n && pre < m && flat_same(cb, sh, lo, s0 + pre, l0 + pre) {pre += 1}
	if hint >= s0 && hint <= s1 && pre > hint - s0 {
		pre = hint - s0
	}
	suf := 0
	for suf < n - pre && suf < m - pre && flat_same(cb, sh, lo, s1 - 1 - suf, l1 - 1 - suf) {suf += 1}
	del := n - pre - suf
	ins := m - pre - suf
	if del == 0 && ins == 0 {
		return false
	}
	insert_from(cb, key, sh, lo, s0 + pre, del, l0 + pre, ins)
	return true
}

// insert_from deletes `del` shared elements at `at` and puts local[l:l+ins]
// in their place.
insert_from :: proc(cb: ^Collab, key: string, sh_in: ^Shared, lo_in: ^Local, at_in, del, l, ins: int) {
	d := cb.doc
	sh := sh_in^
	lo := lo_in^
	pre := at_in
	if del > 0 {
		if cb.suggest {
			// A suggested deletion: mine-and-still-suggested text really goes;
			// everything else is marked for someone to accept.
			i := pre
			for i < pre + del {
				own := sh.si[i] == cb.handle
				j := i
				for j < pre + del && (sh.si[j] == cb.handle) == own {
					j += 1
				}
				if !own {
					crdt.mark(d, key, u64(i), u64(j), "sd", transmute([]u8)cb.handle, .None)
				}
				i = j
			}
			// delete my own suggested insertions, back to front
			k := pre + del
			for k > pre {
				j := k
				for j > pre && sh.si[j - 1] == cb.handle {
					j -= 1
				}
				if j < k {
					crdt.remove(d, key, u64(j), u64(k - j))
					k = j
				} else {
					k -= 1
				}
			}
		} else {
			crdt.remove(d, key, u64(pre), u64(del))
		}
	}
	if ins > 0 {
		flags: u8 = cb.suggest ? crdt.FLAG_SUGGEST : 0
		at := pre
		j := l
		for j < l + ins {
			if lo.bytes[j] == EMBED_BYTE {
				new_embed(cb, key, u64(at), lo.obj[j], lo.tbl[j], flags)
				j += 1
				at += 1
				continue
			}
			k := j
			for k < l + ins && lo.bytes[k] != EMBED_BYTE {
				k += 1
			}
			crdt.insert(d, key, u64(at), lo.bytes[j:k], .Text, flags)
			at += k - j
			j = k
		}
		if cb.suggest {
			crdt.mark(d, key, u64(pre), u64(pre + ins), "si", transmute([]u8)cb.handle, .None)
		}
	}
}

// sync_rest writes what the text diff does not cover: character styles,
// paragraph properties, and the content of tables and pictures.
sync_rest :: proc(cb: ^Collab, key: string, paras: []Paragraph, sh: ^Shared, lo: ^Local) -> (changed: bool) {
	d := cb.doc
	m := len(lo.bytes)
	// Styles: one mark per attribute per differing range. In suggestion mode
	// formatting is not proposed (yet), so it is left to materialise back.
	if !cb.suggest && len(sh.bytes) == len(lo.bytes) {
		for attr in STYLE_ATTRS {
			i := 0
			for i < m {
				if lo.bytes[i] == '\n' || lo.bytes[i] == EMBED_BYTE {
					i += 1
					continue
				}
				want := style_attr_value(lo.style[i], attr)
				have := style_attr_value(sh.style[i], attr)
				if want == have {
					i += 1
					continue
				}
				j := i + 1
				for j < m && lo.bytes[j] != '\n' && lo.bytes[j] != EMBED_BYTE &&
				    style_attr_value(lo.style[j], attr) == want && style_attr_value(sh.style[j], attr) == have {
					j += 1
				}
				crdt.mark(d, key, u64(i), u64(j), attr, transmute([]u8)want, .End)
				changed = true
				i = j
			}
		}
	}

	// Paragraph properties, and what the embeds hold.
	if len(sh.bytes) == len(lo.bytes) {
		for pi in 0 ..< len(paras) {
			pa := &paras[pi]
			owner := para_owner(sh, key, lo.start[:], pi, len(paras))
			if !cb.suggest {
				for f in PARA_FIELDS {
					want := para_field_value(pa, f)
					have := crdt.reg_str(d, owner, f)
					if want != have {
						if want == "" {
							crdt.unset(d, owner, f)
						} else {
							crdt.set_str(d, owner, f, want)
						}
						changed = true
					}
				}
			}
			off := lo.start[pi]
			if off < len(sh.bytes) && sh.bytes[off] == EMBED_BYTE {
				id := sh.ids[off]
				if pa.kind == .Table && pa.table != nil {
					if sync_table(cb, id, pa.table) {changed = true}
				} else if pa.kind == .Image && pa.img != nil {
					want := fmt.tprintf("%.3f", pa.img.scale == 0 ? 1 : pa.img.scale)
					owner_i := fmt.tprintf("i/%s", idkey(id))
					if !cb.suggest && crdt.reg_str(d, owner_i, "s") != want {
						crdt.set_str(d, owner_i, "s", want)
						changed = true
					}
				}
			}
		}
	}
	return
}

// para_owner is the register owner for paragraph `pi`: its newline, or the
// container's end key for the last one.
para_owner :: proc(sh: ^Shared, key: string, starts: []int, pi, count: int) -> string {
	if pi == count - 1 {
		return fmt.tprintf("p/%s$", key)
	}
	nl := starts[pi + 1] - 1
	if nl >= 0 && nl < len(sh.ids) {
		return fmt.tprintf("p/%s", idkey(sh.ids[nl]))
	}
	return fmt.tprintf("p/%s$", key)
}

// new_embed inserts a table or a picture, with its content.
new_embed :: proc(cb: ^Collab, key: string, at: u64, obj: rawptr, is_table: bool, flags: u8) {
	d := cb.doc
	if is_table {
		tbl := (^Table)(obj)
		id := crdt.insert_embed(d, key, at, transmute([]u8)string("T"), flags)
		cb.tables[tbl] = id
		sync_table(cb, id, tbl)
		return
	}
	im := (^Doc_Image)(obj)
	payload := encode_image(im)
	id := crdt.insert_embed(d, key, at, payload, flags)
	cb.images[im] = id
	if im.scale != 0 && im.scale != 1 {
		crdt.set_str(d, fmt.tprintf("i/%s", idkey(id)), "s", fmt.tprintf("%.3f", im.scale))
	}
}

encode_image :: proc(im: ^Doc_Image) -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	append(&b, 'I', u8(im.kind))
	crdt.put_str(&b, im.path)
	crdt.put_str(&b, im.alt)
	append(&b, ..im.bytes)
	return b[:]
}

decode_image :: proc(cb: ^Collab, id: crdt.ID, payload: []u8) -> (Doc_Image, bool) {
	if cached, ok := cb.img_cache[id]; ok {
		return image_clone(&cached), true
	}
	if len(payload) < 2 || payload[0] != 'I' {
		return {}, false
	}
	r := crdt.Reader {
		data = payload,
		i    = 2,
	}
	path := crdt.get_str(&r)
	alt := crdt.get_str(&r)
	if r.bad {
		return {}, false
	}
	im, ok := image_from_bytes(payload[r.i:], path, alt)
	if !ok {
		return {}, false
	}
	cb.img_cache[id] = image_clone(&im)
	return im, true
}

// sync_table writes a table's shape and every cell.
sync_table :: proc(cb: ^Collab, id: crdt.ID, t: ^Table) -> (changed: bool) {
	d := cb.doc
	tk := idkey(id)
	rows_key := fmt.tprintf("r/%s", tk)
	cols_key := fmt.tprintf("k/%s", tk)
	nr_new := len(t.rows)
	nc_new := table_cols(t)

	ax := read_axes(d, id)
	// Rows: what was inserted or removed is found by comparing rows' text
	// from both ends, the same prefix/suffix rule as for text.
	if len(ax.rows) != nr_new {
		old := len(ax.rows)
		pre := 0
		for pre < old && pre < nr_new && row_same(cb, d, id, ax, pre, t, pre) {pre += 1}
		suf := 0
		for suf < old - pre && suf < nr_new - pre && row_same(cb, d, id, ax, old - 1 - suf, t, nr_new - 1 - suf) {suf += 1}
		if old - pre - suf > 0 {
			crdt.remove(d, rows_key, u64(pre), u64(old - pre - suf))
		}
		if nr_new - pre - suf > 0 {
			crdt.insert_virtual(d, rows_key, u64(pre), u64(nr_new - pre - suf))
		}
		changed = true
		ax = read_axes(d, id)
	}
	if len(ax.cols) != nc_new {
		old := len(ax.cols)
		pre := 0
		for pre < old && pre < nc_new && col_same(cb, d, id, ax, pre, t, pre) {pre += 1}
		suf := 0
		for suf < old - pre && suf < nc_new - pre && col_same(cb, d, id, ax, old - 1 - suf, t, nc_new - 1 - suf) {suf += 1}
		if old - pre - suf > 0 {
			crdt.remove(d, cols_key, u64(pre), u64(old - pre - suf))
		}
		if nc_new - pre - suf > 0 {
			crdt.insert_virtual(d, cols_key, u64(pre), u64(nc_new - pre - suf))
		}
		changed = true
		ax = read_axes(d, id)
	}
	// Cells.
	empty := [1]Paragraph{para_make()}
	defer para_destroy(&empty[0])
	for r in 0 ..< min(nr_new, len(ax.rows)) {
		for c in 0 ..< min(nc_new, len(ax.cols)) {
			paras := empty[:]
			if cl := table_cell(t, r, c); cl != nil && len(cl.paras) > 0 {
				paras = cl.paras[:]
			}
			if sync_container(cb, cell_key(id, ax.rows[r], ax.cols[c]), paras) {
				changed = true
			}
		}
	}
	if !cb.suggest {
		owner := fmt.tprintf("t/%s", tk)
		h := t.header ? "1" : "0"
		bd := t.borders ? "1" : "0"
		if crdt.reg_str(d, owner, "h") != h {crdt.set_str(d, owner, "h", h); changed = true}
		if crdt.reg_str(d, owner, "bd") != bd {crdt.set_str(d, owner, "bd", bd); changed = true}
		// A merge is stored as its anchor's identities and the identities of
		// its last row and column, not as counts: a collaborator inserting a
		// row inside the merge then grows it, as it does locally, instead of
		// shifting its end.
		for r in 0 ..< min(nr_new, len(ax.rows)) {
			for c in 0 ..< min(nc_new, len(ax.cols)) {
				want := ""
				if cl := table_cell(t, r, c); cell_is_merged(cl) {
					er := min(r + cell_rspan(cl) - 1, len(ax.rows) - 1)
					ec := min(c + cell_cspan(cl) - 1, len(ax.cols) - 1)
					want = fmt.tprintf("%s %s", idkey(ax.rows[er]), idkey(ax.cols[ec]))
				}
				field := fmt.tprintf("m:%s:%s", idkey(ax.rows[r]), idkey(ax.cols[c]))
				if crdt.reg_str(d, owner, field) != want {
					crdt.set_str(d, owner, field, want)
					changed = true
				}
			}
		}
		for c in 0 ..< min(nc_new, len(ax.cols)) {
			wo := fmt.tprintf("w/%s/%s", tk, idkey(ax.cols[c]))
			want := fmt.tprintf("%.3f", table_width(t, c))
			if crdt.reg_str(d, wo, "w") != want {
				crdt.set_str(d, wo, "w", want)
				changed = true
			}
		}
	}
	remember_axes(cb, id, ax)
	return
}

// remember_axes keeps a table's row and column identities, which is how a
// caret inside a cell finds its container.
remember_axes :: proc(cb: ^Collab, id: crdt.ID, ax: Table_Axes) {
	axes := Table_Axes {
		rows = make([dynamic]crdt.ID, 0, len(ax.rows)),
		cols = make([dynamic]crdt.ID, 0, len(ax.cols)),
	}
	append(&axes.rows, ..ax.rows[:])
	append(&axes.cols, ..ax.cols[:])
	if old, ok := cb.axes[id]; ok {
		delete(old.rows)
		delete(old.cols)
	}
	cb.axes[id] = axes
}

read_axes :: proc(d: ^crdt.Doc, id: crdt.ID) -> Table_Axes {
	ax: Table_Axes
	ax.rows = make([dynamic]crdt.ID, context.temp_allocator)
	ax.cols = make([dynamic]crdt.ID, context.temp_allocator)
	tk := idkey(id)
	for k, which in ([2]string{fmt.tprintf("r/%s", tk), fmt.tprintf("k/%s", tk)}) {
		sp := crdt.read_spans(d, k)
		for s in sp.spans {
			for i in 0 ..< s.len {
				nid := crdt.ID{s.first.agent, s.first.seq + i}
				if which == 0 {append(&ax.rows, nid)} else {append(&ax.cols, nid)}
			}
		}
	}
	return ax
}

cell_plain :: proc(d: ^crdt.Doc, key: string) -> string {
	return crdt.read_text(d, key)
}

local_cell_plain :: proc(t: ^Table, r, c: int) -> string {
	cl := table_cell(t, r, c)
	if cl == nil {return ""}
	b := strings.builder_make(context.temp_allocator)
	for &pa, i in cl.paras {
		if i > 0 {strings.write_byte(&b, '\n')}
		for &run in pa.runs {strings.write_bytes(&b, run.text[:])}
	}
	return strings.to_string(b)
}

row_same :: proc(cb: ^Collab, d: ^crdt.Doc, id: crdt.ID, ax: Table_Axes, ro: int, t: ^Table, rn: int) -> bool {
	for c in 0 ..< min(len(ax.cols), table_cols(t)) {
		if cell_plain(d, cell_key(id, ax.rows[ro], ax.cols[c])) != local_cell_plain(t, rn, c) {
			return false
		}
	}
	return true
}

col_same :: proc(cb: ^Collab, d: ^crdt.Doc, id: crdt.ID, ax: Table_Axes, co: int, t: ^Table, cn: int) -> bool {
	for r in 0 ..< min(len(ax.rows), len(t.rows)) {
		if cell_plain(d, cell_key(id, ax.rows[r], ax.cols[co])) != local_cell_plain(t, r, cn) {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Shared -> local
// ---------------------------------------------------------------------------

// materialise_container rebuilds the paragraphs of one container: split at
// newlines, each paragraph taking the properties its newline carries. A
// paragraph is normally all text or exactly one embed; if concurrent edits
// left text beside an embed in one paragraph, the embed is shown as its own
// paragraph between the text before and after it.
materialise_container :: proc(cb: ^Collab, key: string) -> [dynamic]Paragraph {
	d := cb.doc
	sh := read_shared(d, key)
	out := make([dynamic]Paragraph, 0, 8)
	sp := shared_paras(&sh)
	np := len(sp) - 1
	for k in 0 ..< np {
		s0, s1 := sp[k], sp[k + 1] - 1
		owner := k == np - 1 ? fmt.tprintf("p/%s$", key) : fmt.tprintf("p/%s", idkey(sh.ids[s1]))
		pa := para_make()
		clear(&pa.runs)
		i := s0
		for i < s1 {
			if sh.bytes[i] == EMBED_BYTE {
				if len(pa.runs) > 0 {
					normalise(&pa)
					append(&out, pa)
					pa = para_make()
					clear(&pa.runs)
				}
				append(&out, embed_para(cb, key, sh.ids[i], sh.emb[i], owner))
				i += 1
				continue
			}
			j := i
			cs := sh.style[i]
			for j < s1 && sh.bytes[j] != EMBED_BYTE && sh.style[j] == cs {
				j += 1
			}
			append(&pa.runs, run_make(cs, string(sh.bytes[i:j])))
			i = j
		}
		last_was_embed := s1 > s0 && sh.bytes[s1 - 1] == EMBED_BYTE
		if len(pa.runs) > 0 || !last_was_embed {
			if len(pa.runs) == 0 {
				append(&pa.runs, run_make({}))
			}
			normalise(&pa)
			para_apply_fields(&pa, d, owner)
			append(&out, pa)
		} else {
			para_destroy(&pa)
		}
	}
	if len(out) == 0 {
		append(&out, para_make())
	}
	return out
}

embed_para :: proc(cb: ^Collab, key: string, id: crdt.ID, payload: []u8, owner: string) -> Paragraph {
	d := cb.doc
	np := Paragraph{}
	np.runs = make([dynamic]Run, 0, 1)
	append(&np.runs, run_make({}))
	if len(payload) > 0 && payload[0] == 'T' {
		np.table = new(Table)
		np.table^ = materialise_table(cb, id)
		cb.tables[np.table] = id
	} else if im, ok := decode_image(cb, id, payload); ok {
		np.img = new(Doc_Image)
		np.img^ = im
		if s := crdt.reg_str(d, fmt.tprintf("i/%s", idkey(id)), "s"); s != "" {
			np.img.scale, _ = strconv.parse_f32(s)
		}
		cb.images[np.img] = id
	}
	para_apply_fields(&np, d, owner)
	np.kind = np.table != nil ? .Table : (np.img != nil ? .Image : .Body)
	return np
}

materialise_table :: proc(cb: ^Collab, id: crdt.ID) -> Table {
	d := cb.doc
	ax := read_axes(d, id)
	tk := idkey(id)
	owner := fmt.tprintf("t/%s", tk)
	t := Table {
		rows    = make([dynamic]Row, 0, len(ax.rows)),
		widths  = make([dynamic]f32, 0, len(ax.cols)),
		header  = crdt.reg_str(d, owner, "h", "1") == "1",
		borders = crdt.reg_str(d, owner, "bd", "1") == "1",
	}
	nr := max(1, len(ax.rows))
	nc := max(1, len(ax.cols))
	for r in 0 ..< nr {
		row := Row {
			cells = make([dynamic]Cell, 0, nc),
		}
		for c in 0 ..< nc {
			cl := Cell{}
			if r < len(ax.rows) && c < len(ax.cols) {
				cl.paras = materialise_container(cb, cell_key(id, ax.rows[r], ax.cols[c]))
			} else {
				cl = cell_make()
			}
			append(&row.cells, cl)
		}
		append(&t.rows, row)
	}
	have_all := true
	for c in 0 ..< nc {
		w: f32 = 0
		if c < len(ax.cols) {
			if s := crdt.reg_str(d, fmt.tprintf("w/%s/%s", tk, idkey(ax.cols[c])), "w"); s != "" {
				w, _ = strconv.parse_f32(s)
			}
		}
		if w <= 0 {have_all = false}
		append(&t.widths, w)
	}
	if !have_all {
		for c in 0 ..< nc {
			if t.widths[c] <= 0 {t.widths[c] = CONTENT_W / f32(nc)}
		}
		table_fit_widths(&t)
	}
	// Merges: an end whose row or column has since been deleted, or that now
	// sits before the anchor, is ignored and the cell comes back unmerged.
	for r in 0 ..< min(nr, len(ax.rows)) {
		for c in 0 ..< min(nc, len(ax.cols)) {
			v := crdt.reg_str(d, owner, fmt.tprintf("m:%s:%s", idkey(ax.rows[r]), idkey(ax.cols[c])))
			sp := strings.index_byte(v, ' ')
			if sp <= 0 {
				continue
			}
			er, ec := -1, -1
			for k in r ..< len(ax.rows) {
				if idkey(ax.rows[k]) == v[:sp] {er = k; break}
			}
			for k in c ..< len(ax.cols) {
				if idkey(ax.cols[k]) == v[sp + 1:] {ec = k; break}
			}
			if er >= 0 && ec >= 0 {
				t.rows[r].cells[c].rspan = er - r + 1
				t.rows[r].cells[c].cspan = ec - c + 1
			}
		}
	}
	table_normalise(&t)
	remember_axes(cb, id, ax)
	return t
}

// ---------------------------------------------------------------------------
// Positions: the app's Pos <-> (container, flat offset)
// ---------------------------------------------------------------------------

Where :: struct {
	key: string,
	off: int,
}

// pos_where gives the container and flat offset of a caret.
pos_where :: proc(st: ^State, q: Pos) -> Where {
	cb := &st.collab
	d := &st.doc
	if in_cell(d, q) {
		pa := &d.paras[q.para]
		id, ok := cb.tables[pa.table]
		ax, ok2 := cb.axes[id]
		if ok && ok2 && q.row < len(ax.rows) && q.col < len(ax.cols) {
			cl := table_cell(pa.table, q.row, q.col)
			off := 0
			for i in 0 ..< q.cpara {
				off += para_flat_len(&cl.paras[i]) + 1
			}
			return Where{cell_key(id, ax.rows[q.row], ax.cols[q.col]), off + q.off}
		}
	}
	off := 0
	for i in 0 ..< min(q.para, len(d.paras)) {
		off += para_flat_len(&d.paras[i]) + 1
	}
	return Where{"b", off + q.off}
}

para_flat_len :: proc(pa: ^Paragraph) -> int {
	if (pa.kind == .Table && pa.table != nil) || (pa.kind == .Image && pa.img != nil) {
		return 1
	}
	return para_len(pa)
}

// where_pos maps back. An offset inside an embed's paragraph lands at its
// start.
where_pos :: proc(st: ^State, w: Where) -> Pos {
	d := &st.doc
	cb := &st.collab
	paras: []Paragraph = d.paras[:]
	base := Pos{}
	if w.key != "b" {
		found := false
		outer: for pi in 0 ..< len(d.paras) {
			pa := &d.paras[pi]
			if pa.kind != .Table || pa.table == nil {continue}
			id := cb.tables[pa.table]
			ax, ok := cb.axes[id]
			if !ok {continue}
			for r in 0 ..< len(ax.rows) {
				for c in 0 ..< len(ax.cols) {
					if cell_key(id, ax.rows[r], ax.cols[c]) == w.key {
						cl := table_cell(pa.table, r, c)
						if cl == nil {break outer}
						paras = cl.paras[:]
						base = Pos{para = pi, row = r, col = c}
						found = true
						break outer
					}
				}
			}
		}
		if !found {
			return pos_clamp(d, Pos{})
		}
	}
	off := w.off
	for i in 0 ..< len(paras) {
		l := para_flat_len(&paras[i])
		if off <= l || i == len(paras) - 1 {
			q := base
			if w.key == "b" {
				q.para = i
			} else {
				q.cpara = i
			}
			q.off = text_kind(paras[i].kind) ? clamp(off, 0, l) : 0
			return pos_clamp(d, q)
		}
		off -= l + 1
	}
	return pos_clamp(d, base)
}

// A sticky caret: the container, and the element it sits after.
Sticky_Pos :: struct {
	key: string,
	st:  crdt.Sticky,
}

sticky_of :: proc(st: ^State, q: Pos) -> Sticky_Pos {
	w := pos_where(st, q)
	return Sticky_Pos{strings.clone(w.key, context.temp_allocator), crdt.sticky_at(st.collab.doc, w.key, u64(max(0, w.off)))}
}

sticky_resolve :: proc(st: ^State, s: Sticky_Pos) -> Pos {
	off := crdt.sticky_resolve(st.collab.doc, s.st)
	return where_pos(st, Where{s.key, int(off)})
}

sticky_encode :: proc(s: Sticky_Pos) -> string {
	if s.st.after == {} {
		return fmt.tprintf("%s|", s.key)
	}
	return fmt.tprintf("%s|%s", s.key, idkey(s.st.after))
}

sticky_decode :: proc(s: string) -> (Sticky_Pos, bool) {
	bar := strings.last_index_byte(s, '|')
	if bar < 0 {
		return {}, false
	}
	out := Sticky_Pos {
		key = s[:bar],
	}
	if bar + 1 < len(s) {
		id, ok := parse_idkey(s[bar + 1:])
		if !ok {return {}, false}
		out.st.after = id
	}
	return out, true
}

// ---------------------------------------------------------------------------
// The binding's entry points
// ---------------------------------------------------------------------------

collab_init :: proc(cb: ^Collab, d: ^crdt.Doc) {
	cb.doc = d
	cb.tables = make(map[^Table]crdt.ID)
	cb.images = make(map[^Doc_Image]crdt.ID)
	cb.axes = make(map[crdt.ID]Table_Axes)
	cb.img_cache = make(map[crdt.ID]Doc_Image)
	cb.hint = -1
	cb.on = true
}

collab_destroy :: proc(cb: ^Collab) {
	if !cb.on {return}
	delete(cb.tables)
	delete(cb.images)
	for _, ax in cb.axes {
		delete(ax.rows)
		delete(ax.cols)
	}
	delete(cb.axes)
	for _, &im in cb.img_cache {image_destroy(&im)}
	delete(cb.img_cache)
	decos_clear(cb)
	delete(cb.decos)
	comments_clear(cb)
	delete(cb.comments)
	if cb.sess != nil {
		client.session_close(cb.sess)
	} else if cb.doc != nil {
		crdt.doc_destroy(cb.doc)
	}
	cb^ = {}
}

// collab_note_edit is called by edit_begin, before the model changes.
collab_note_edit :: proc(st: ^State, kind: Edit_Kind) {
	cb := &st.collab
	if !cb.on {return}
	if !cb.pending {
		cb.pending = true
		w := pos_where(st, st.caret)
		a := pos_where(st, st.anchor)
		cb.hint = w.key == a.key ? min(w.off, a.off) : -1
		delete(cb.hint_key)
		cb.hint_key = strings.clone(w.key)
		cb.caret_before = w.off
		cb.tag = kind
		before := sticky_encode(sticky_of(st, st.caret))
		crdt.begin(cb.doc, kind == .Structural ? 0 : int(kind), transmute([]u8)before)
	}
}

// collab_sync writes this frame's local edits into the CRDT and hands them to
// the network. Returns whether anything was written.
collab_sync :: proc(st: ^State) -> bool {
	cb := &st.collab
	if !cb.on || !cb.pending {
		return false
	}
	cb.pending = false
	caret_w := pos_where(st, st.caret)
	hint := cb.hint_key == "b" ? cb.hint : -1
	changed := sync_container(cb, "b", st.doc.paras[:], hint)
	crdt.commit(cb.doc)
	if cb.sess != nil {
		client.flush(cb.sess)
	}
	if cb.suggest && changed {
		// What was proposed is shown as the CRDT has it: struck through,
		// underlined, formatting reverted.
		off := caret_w.off
		if cb.caret_before == caret_w.off && caret_w.key == cb.hint_key {
			// a forward delete: step over what was just struck out
			off = caret_w.off + (cb.caret_before - caret_w.off)
		}
		collab_materialise(st, Sticky_Pos{}, false)
		q := where_pos(st, Where{caret_w.key, off})
		st.caret, st.anchor = q, q
	} else {
		collab_refresh_decos(st)
	}
	return changed
}

// collab_save_carets records the caret and selection as sticky positions.
// Call it before remote updates are applied to the CRDT.
collab_save_carets :: proc(st: ^State) {
	cb := &st.collab
	c := sticky_of(st, st.caret)
	a := sticky_of(st, st.anchor)
	delete(cb.saved_caret.key)
	delete(cb.saved_anchor.key)
	cb.saved_caret = Sticky_Pos{strings.clone(c.key), c.st}
	cb.saved_anchor = Sticky_Pos{strings.clone(a.key), a.st}
	cb.saved = true
}

collab_break :: proc(st: ^State) {
	if st.collab.on {
		crdt.close_group(st.collab.doc)
	}
}

// collab_materialise rebuilds the model from the CRDT, keeping the caret and
// selection on the same characters.
collab_materialise :: proc(st: ^State, _: Sticky_Pos, keep_caret := true) {
	cb := &st.collab
	sc, sa: Sticky_Pos
	if keep_caret {
		if cb.saved {
			// captured before the remote updates went in, which is the only
			// moment the model and the CRDT agree on what an offset means
			sc, sa = cb.saved_caret, cb.saved_anchor
		} else {
			sc = sticky_of(st, st.caret)
			sa = sticky_of(st, st.anchor)
		}
	}
	cb.saved = false
	clear(&cb.tables)
	clear(&cb.images)
	paras := materialise_container(cb, "b")
	if len(paras) == 0 {
		append(&paras, para_make())
	}
	doc_destroy(&st.doc)
	st.doc = Doc {
		paras = paras,
	}
	cb.materialised += 1
	if keep_caret {
		st.caret = sticky_resolve(st, sc)
		st.anchor = sticky_resolve(st, sa)
	}
	st.caret = pos_clamp(&st.doc, st.caret)
	st.anchor = pos_clamp(&st.doc, st.anchor)
	st.dirty = true
	collab_refresh_decos(st)
}

// collab_undo reverts this window's last step, and only this window's.
collab_undo :: proc(st: ^State, redo := false) -> bool {
	cb := &st.collab
	before: []u8
	ok: bool
	if redo {
		ok = crdt.redo(cb.doc)
	} else {
		before, ok = crdt.undo(cb.doc)
	}
	if !ok {
		return false
	}
	if cb.sess != nil {
		client.flush(cb.sess)
	}
	collab_materialise(st, {}, true)
	if len(before) > 0 {
		if s, good := sticky_decode(string(before)); good {
			q := sticky_resolve(st, s)
			st.caret, st.anchor = q, q
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Comments and suggestions
// ---------------------------------------------------------------------------

decos_clear :: proc(cb: ^Collab) {
	for dc in cb.decos {delete(dc.id)}
	clear(&cb.decos)
}

comments_clear :: proc(cb: ^Collab) {
	for &c in cb.comments {
		delete(c.id)
		delete(c.text)
		delete(c.author)
		delete(c.name)
		delete(c.color)
		delete(c.quote)
		for r in c.replies {
			delete(r.author)
			delete(r.name)
			delete(r.color)
			delete(r.text)
		}
		delete(c.replies)
	}
	clear(&cb.comments)
}

// collab_refresh_decos recomputes the comment highlights and suggestion
// marks for every container, in the app's block coordinates.
collab_refresh_decos :: proc(st: ^State) {
	cb := &st.collab
	if !cb.on {return}
	decos_clear(cb)
	comments_clear(cb)
	refresh_container_decos(st, "b")
	for &pa in st.doc.paras {
		if pa.kind != .Table || pa.table == nil {continue}
		id := cb.tables[pa.table]
		ax, ok := cb.axes[id]
		if !ok {continue}
		for r in ax.rows {
			for c in ax.cols {
				refresh_container_decos(st, cell_key(id, r, c))
			}
		}
	}
	// threads with no live range still appear (detached), from their registers
	for owner in cb.doc.regs {
		if !strings.has_prefix(owner, "cmt/") {continue}
		cid := owner[4:]
		have := false
		for c in cb.comments {if c.id == cid {have = true}}
		if !have && crdt.reg_str(cb.doc, owner, "text") != "" {
			append(&cb.comments, comment_view(cb, cid, Pos{}, "", false))
		}
	}
	// reading order
	for i in 1 ..< len(cb.comments) {
		j := i
		for j > 0 && pos_less(cb.comments[j].anchor, cb.comments[j - 1].anchor) {
			cb.comments[j], cb.comments[j - 1] = cb.comments[j - 1], cb.comments[j]
			j -= 1
		}
	}
}

comment_view :: proc(cb: ^Collab, cid: string, anchor: Pos, quote: string, alive: bool) -> Comment_View {
	d := cb.doc
	owner := fmt.tprintf("cmt/%s", cid)
	at, _ := strconv.parse_i64(crdt.reg_str(d, owner, "at"))
	cv := Comment_View {
		id       = strings.clone(cid),
		text     = strings.clone(crdt.reg_str(d, owner, "text")),
		author   = strings.clone(crdt.reg_str(d, owner, "by")),
		name     = strings.clone(crdt.reg_str(d, owner, "name")),
		color    = strings.clone(crdt.reg_str(d, owner, "color")),
		at       = at,
		resolved = crdt.reg_str(d, owner, "resolved") == "1",
		quote    = strings.clone(quote),
		anchor   = anchor,
		alive    = alive,
	}
	sp := crdt.read_spans(d, fmt.tprintf("cr/%s", cid))
	for s in sp.spans {
		if s.kind != .Embed {continue}
		parts := strings.split(string(s.content), "\x1f", context.temp_allocator)
		if len(parts) < 5 {continue}
		t, _ := strconv.parse_i64(parts[3])
		append(&cv.replies, Reply_View{
			author = strings.clone(parts[0]),
			name = strings.clone(parts[1]),
			color = strings.clone(parts[2]),
			at = t,
			text = strings.clone(parts[4]),
		})
	}
	return cv
}

refresh_container_decos :: proc(st: ^State, key: string) {
	cb := &st.collab
	d := cb.doc
	s, ok := d.seqs[key]
	if !ok {return}
	sh := read_shared(d, key)
	// suggestions: runs of si / sd
	i := 0
	for i < len(sh.bytes) {
		if sh.si[i] == "" && sh.sd[i] == "" {
			i += 1
			continue
		}
		kind := sh.sd[i] != "" ? Deco_Kind.Sugg_Del : Deco_Kind.Sugg_Ins
		who := kind == .Sugg_Del ? sh.sd[i] : sh.si[i]
		j := i + 1
		for j < len(sh.bytes) && sh.bytes[j] != '\n' && (kind == .Sugg_Del ? sh.sd[j] == who : (sh.sd[j] == "" && sh.si[j] == who)) {
			j += 1
		}
		add_deco_range(st, key, i, j, kind, who)
		i = max(j, i + 1)
	}
	// comment ranges: live marks named cm:<id>
	for m in s.marks {
		if m.deleted || !strings.has_prefix(m.attr, "cm:") || len(m.value) == 0 {continue}
		cid := m.attr[3:]
		from, to := mark_range(d, m)
		if to <= from {
			append(&cb.comments, comment_view(cb, cid, where_pos(st, Where{key, from}), "", false))
			continue
		}
		kind := cid == cb.active_comment ? Deco_Kind.Comment_Active : Deco_Kind.Comment
		add_deco_range(st, key, from, to, kind, cid)
		quote := strings.builder_make(context.temp_allocator)
		for k in from ..< min(to, len(sh.bytes)) {
			b := sh.bytes[k]
			strings.write_byte(&quote, b == '\n' ? ' ' : b)
		}
		append(&cb.comments, comment_view(cb, cid, where_pos(st, Where{key, from}), strings.to_string(quote), true))
	}
}

// mark_range is a mark's current visible extent.
mark_range :: proc(d: ^crdt.Doc, m: ^crdt.Mark) -> (from, to: int) {
	anchor_off :: proc(d: ^crdt.Doc, a: crdt.Anchor, s: ^crdt.Seq) -> int {
		if a.id == {} {
			return a.after ? int(s.vis) : 0
		}
		off, alive, found := crdt.offset_of(d, a.id)
		if !found {return 0}
		if a.after && alive {return int(off) + 1}
		return int(off)
	}
	return anchor_off(d, m.start, m.seq), anchor_off(d, m.end, m.seq)
}

// add_deco_range splits a flat range into per-block decorations.
add_deco_range :: proc(st: ^State, key: string, from, to: int, kind: Deco_Kind, id: string) {
	cb := &st.collab
	a := where_pos(st, Where{key, from})
	b := where_pos(st, Where{key, to})
	color := deco_color(st, id, kind)
	for blk in blocks_between(&st.doc, a, b) {
		f, t := blk_range(&st.doc, blk, a, b)
		if t <= f {continue}
		append(&cb.decos, Deco{blk = blk, from = f, to = t, kind = kind, color = color, id = strings.clone(id)})
	}
}

deco_color :: proc(st: ^State, id: string, kind: Deco_Kind) -> u32 {
	switch kind {
	case .Comment:
		return 0xfde68a
	case .Comment_Active:
		return 0xfbbf24
	case .Sugg_Ins, .Sugg_Del:
		return identity_rgb(peer_color_for(st, id))
	}
	return 0x16a34a
}

// peer_color_for finds the palette colour of the identity with `handle`.
peer_color_for :: proc(st: ^State, handle: string) -> string {
	cb := &st.collab
	if handle == cb.handle {return cb.color}
	if cb.sess != nil {
		for p in cb.sess.peers {
			if p.identity.handle == handle {return p.identity.color}
		}
	}
	return "emerald"
}

// peer_name_for is the display name of the identity with `handle`, as far as
// this window knows it (itself, or someone present).
peer_name_for :: proc(st: ^State, handle: string) -> string {
	cb := &st.collab
	if handle == cb.handle {return cb.name}
	if cb.sess != nil {
		for p in cb.sess.peers {
			if p.identity.handle == handle {return p.identity.display_name}
		}
	}
	return handle
}

// collab_comment adds a comment on the selection. Returns its id.
collab_comment :: proc(st: ^State, text: string) -> string {
	cb := &st.collab
	lo, hi, has := selection(st)
	if !cb.on || !has || strings.trim_space(text) == "" {
		return ""
	}
	a := pos_where(st, lo)
	b := pos_where(st, hi)
	if a.key != b.key {
		b = Where{a.key, a.off + max(1, pos_para_len(&st.doc, lo) - lo.off)}
	}
	cid := fmt.aprintf("%x", u64(time.now()._nsec) ~ cb.doc.agent)
	d := cb.doc
	crdt.begin(d)
	owner := fmt.tprintf("cmt/%s", cid)
	crdt.set_str(d, owner, "text", text)
	crdt.set_str(d, owner, "by", cb.handle)
	crdt.set_str(d, owner, "name", cb.name)
	crdt.set_str(d, owner, "color", cb.color)
	crdt.set_str(d, owner, "at", fmt.tprintf("%d", time.time_to_unix(time.now())))
	crdt.mark(d, a.key, u64(a.off), u64(b.off), fmt.tprintf("cm:%s", cid), transmute([]u8)string("1"), .None)
	crdt.commit(d)
	if cb.sess != nil {client.flush(cb.sess)}
	cb.active_comment = cid
	collab_refresh_decos(st)
	return cid
}

collab_reply :: proc(st: ^State, cid, text: string) {
	cb := &st.collab
	if !cb.on || strings.trim_space(text) == "" {return}
	key := fmt.tprintf("cr/%s", cid)
	s := crdt.seq_get(cb.doc, key)
	payload := fmt.tprintf("%s\x1f%s\x1f%s\x1f%d\x1f%s", cb.handle, cb.name, cb.color, time.time_to_unix(time.now()), text)
	crdt.begin(cb.doc)
	crdt.insert_embed(cb.doc, key, s.vis, transmute([]u8)payload)
	crdt.commit(cb.doc)
	if cb.sess != nil {client.flush(cb.sess)}
	collab_refresh_decos(st)
}

collab_resolve :: proc(st: ^State, cid: string, resolved := true) {
	cb := &st.collab
	if !cb.on {return}
	crdt.begin(cb.doc)
	crdt.set_str(cb.doc, fmt.tprintf("cmt/%s", cid), "resolved", resolved ? "1" : "0")
	crdt.commit(cb.doc)
	if cb.sess != nil {client.flush(cb.sess)}
	collab_refresh_decos(st)
}

// collab_decide accepts or rejects every suggestion that touches the caret's
// paragraph range [lo, hi] (the selection, or the suggestion under the caret).
collab_decide :: proc(st: ^State, accept: bool) -> int {
	cb := &st.collab
	if !cb.on {return 0}
	lo, hi, has := selection(st)
	if !has {lo, hi = st.caret, st.caret}
	a := pos_where(st, lo)
	b := pos_where(st, hi)
	key := a.key
	sh := read_shared(cb.doc, key)
	// widen to the whole suggestion(s) the range touches
	from, to := a.off, b.key == key ? b.off : a.off
	sugg :: proc(sh: ^Shared, i: int) -> bool {return i >= 0 && i < len(sh.bytes) && (sh.si[i] != "" || sh.sd[i] != "")}
	if !sugg(&sh, from) && sugg(&sh, from - 1) {from -= 1}
	for from > 0 && sugg(&sh, from - 1) {from -= 1}
	if to <= from {to = from + 1}
	for to < len(sh.bytes) && sugg(&sh, to) {to += 1}
	if from >= len(sh.bytes) {return 0}
	crdt.begin(cb.doc)
	n := 0
	// insertions
	k := to
	for k > from {
		j := k
		for j > from && sh.si[j - 1] != "" && sh.sd[j - 1] == "" {j -= 1}
		if j < k {
			if accept {
				crdt.mark(cb.doc, key, u64(j), u64(k), "si", transmute([]u8)string("+"), .None)
			} else {
				crdt.remove(cb.doc, key, u64(j), u64(k - j))
			}
			n += 1
			k = j
		} else {
			k -= 1
		}
	}
	sh = read_shared(cb.doc, key)
	to = min(to, len(sh.bytes))
	k = to
	for k > from {
		j := k
		for j > from && sh.sd[j - 1] != "" {j -= 1}
		if j < k {
			if accept {
				crdt.remove(cb.doc, key, u64(j), u64(k - j))
			} else {
				crdt.mark(cb.doc, key, u64(j), u64(k), "sd", nil, .None)
			}
			n += 1
			k = j
		} else {
			k -= 1
		}
	}
	crdt.commit(cb.doc)
	if cb.sess != nil {client.flush(cb.sess)}
	collab_materialise(st, {}, true)
	return n
}

// identity_rgb is the 500 shade of an identity's palette colour.
identity_rgb :: proc(name: string) -> u32 {
	switch name {
	case "red":
		return 0xef4444
	case "orange":
		return 0xf97316
	case "amber":
		return 0xf59e0b
	case "yellow":
		return 0xeab308
	case "lime":
		return 0x84cc16
	case "green":
		return 0x22c55e
	case "emerald":
		return 0x10b981
	case "teal":
		return 0x14b8a6
	case "cyan":
		return 0x06b6d4
	case "sky":
		return 0x0ea5e9
	case "blue":
		return 0x3b82f6
	case "violet":
		return 0x8b5cf6
	case "purple":
		return 0xa855f7
	case "fuchsia":
		return 0xd946ef
	case "pink":
		return 0xec4899
	case "rose":
		return 0xf43f5e
	}
	return 0x6366f1 // indigo
}
