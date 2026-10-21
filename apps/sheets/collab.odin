// Collaborative spreadsheets: the workbook on the CRDT (cloud/collab/crdt).
//
// The shape of the shared workbook:
//
//	S                       the sheet order: one element per placement, its
//	                        payload the sheet's key (a movable list: moving a
//	                        sheet places it again and points its "slot" there)
//	sh/<sheet>              name, slot, frozen rows/cols, gone, merges+charts
//	r/<sheet>  k/<sheet>    rows and columns: content-free elements, one per
//	                        row/column, so a million-row axis is one item
//	c/<sheet>/<row>/<col>   a cell, by row and column *identity*: v (input), f (format)
//	w/<sheet>/<col>         a column width;  h/<sheet>/<row>  a row height
//	book                    names (named ranges)
//	cmt/<id>                a comment thread, anchored to a cell's identity
//
// Why identities, not addresses: when Alice inserts a row above row 5 while
// Bob types into B5, Bob's value must land in what is now B6. Keyed by the
// row's identity it does, with no transformation at all. Formulas get the
// same treatment: an input like `=SUM(B2:B9)*Sheet2!$A$1` is stored with each
// reference replaced by an anchor naming the target sheet's key and the row
// and column identities, and rendered back to A1 text against the current
// axes. So a formula written concurrently with a row insertion still points
// at the cells its author meant, and a reference whose row was deleted
// renders as #REF!, as it would locally.
//
// Values are never shared: every replica recalculates from the inputs, which
// are what converge. Two people writing one cell at once is last-writer-wins
// (Lamport order); the loser's value stays in the version history.
package main

import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strconv"
import "core:strings"
import p "palmy:."
import client "../../cloud/collab/client"
import crdt "../../cloud/collab/crdt"
import collabui "../../cloud/collab/ui"

ANCHOR_OPEN :: '\x01'
ANCHOR_SEP :: '\x02'
ANCHOR_CLOSE :: '\x03'

Struct_Op :: struct {
	sheet:    ^Sheet,
	insert:   bool,
	axis_row: bool,
	at, n:    int,
}

Sheets_Collab :: struct {
	on:         bool,
	ui:         collabui.State,
	doc:        ^crdt.Doc,
	keys:       map[^Sheet]string,
	pending:    bool,
	structural: [dynamic]Struct_Op,
	saved:      bool,
	saved_cur:  Cell_Anchor,
	saved_anc:  Cell_Anchor,
	comments:   [dynamic]Cell_Comment,
	materialised: int,
}

Cell_Anchor :: struct {
	sheet: string,
	row:   crdt.ID,
	col:   crdt.ID,
	ok:    bool,
}

Cell_Comment :: struct {
	id:       string,
	text:     string,
	name:     string,
	color:    string,
	resolved: bool,
	sheet:    int,
	addr:     Addr,
	alive:    bool,
}

collab: Sheets_Collab

idkey :: proc(id: crdt.ID, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%x.%d", id.agent, id.seq, allocator = allocator)
}

parse_idkey :: proc(s: string) -> (crdt.ID, bool) {
	dot := strings.index_byte(s, '.')
	if dot <= 0 {return {}, false}
	a, ok1 := strconv.parse_u64_of_base(s[:dot], 16)
	q, ok2 := strconv.parse_u64_of_base(s[dot + 1:], 10)
	return crdt.ID{a, q}, ok1 && ok2
}

// ---------------------------------------------------------------------------
// Axes: index <-> identity
// ---------------------------------------------------------------------------

Axis_Run :: struct {
	first: crdt.ID,
	len:   int,
	start: int,
}

Axis :: struct {
	runs:  [dynamic]Axis_Run,
	total: int,
}

axis_read :: proc(d: ^crdt.Doc, key: string) -> Axis {
	ax: Axis
	ax.runs = make([dynamic]Axis_Run, 0, 4, context.temp_allocator)
	sp := crdt.read_spans(d, key)
	for s in sp.spans {
		if n := len(ax.runs); n > 0 {
			last := &ax.runs[n - 1]
			if last.first.agent == s.first.agent && last.first.seq + u64(last.len) == s.first.seq {
				last.len += int(s.len)
				ax.total += int(s.len)
				continue
			}
		}
		append(&ax.runs, Axis_Run{s.first, int(s.len), ax.total})
		ax.total += int(s.len)
	}
	return ax
}

axis_id :: proc(ax: ^Axis, i: int) -> (crdt.ID, bool) {
	lo, hi := 0, len(ax.runs)
	for lo < hi {
		mid := (lo + hi) / 2
		if ax.runs[mid].start <= i {lo = mid + 1} else {hi = mid}
	}
	k := lo - 1
	if k < 0 || i >= ax.runs[k].start + ax.runs[k].len {
		return {}, false
	}
	r := ax.runs[k]
	return crdt.ID{r.first.agent, r.first.seq + u64(i - r.start)}, true
}

axis_index :: proc(ax: ^Axis, id: crdt.ID) -> (int, bool) {
	for r in ax.runs {
		if r.first.agent == id.agent && id.seq >= r.first.seq && id.seq < r.first.seq + u64(r.len) {
			return r.start + int(id.seq - r.first.seq), true
		}
	}
	return -1, false
}

Book_Axes :: struct {
	keys: [dynamic]string, // sheet keys, in order
	rows: [dynamic]Axis,
	cols: [dynamic]Axis,
}

read_book_axes :: proc(d: ^crdt.Doc) -> Book_Axes {
	ba: Book_Axes
	ba.keys = crdt_sheet_order(d)
	for k in ba.keys {
		append(&ba.rows, axis_read(d, fmt.tprintf("r/%s", k)))
		append(&ba.cols, axis_read(d, fmt.tprintf("k/%s", k)))
	}
	return ba
}

// crdt_sheet_order lists the live sheets' keys in tab order.
crdt_sheet_order :: proc(d: ^crdt.Doc) -> [dynamic]string {
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	sp := crdt.read_spans(d, "S")
	seen := make(map[string]bool, 4, context.temp_allocator)
	for s in sp.spans {
		if s.kind != .Embed {continue}
		k := string(s.content)
		owner := fmt.tprintf("sh/%s", k)
		if crdt.reg_str(d, owner, "gone") == "1" {continue}
		if crdt.reg_str(d, owner, "slot") != idkey(s.first) {continue}
		if k in seen {continue}
		seen[k] = true
		append(&out, strings.clone(k, context.temp_allocator))
	}
	return out
}

// ---------------------------------------------------------------------------
// Formulas: A1 <-> anchored
// ---------------------------------------------------------------------------

// anchor_formula replaces every reference in a formula with an anchor to the
// identities of the rows and columns it names. Anything it cannot anchor (a
// sheet that does not exist, a malformed formula) stays as text.
anchor_formula :: proc(bk: ^Book, own: int, ba: ^Book_Axes, text: string) -> string {
	if len(text) == 0 || text[0] != '=' {
		return text
	}
	b := strings.builder_make(context.temp_allocator)
	lx := Lexer{src = text, i = 1}
	strings.write_byte(&b, '=')
	last := 1
	prev_kind := Tok_Kind.End
	prev_target := own
	for {
		for lx.i < len(text) && (text[lx.i] == ' ' || text[lx.i] == '\t' || text[lx.i] == '\n' || text[lx.i] == '\r') {
			lx.i += 1
		}
		start := lx.i
		t, ok := lex_next(&lx)
		if !ok || t.kind == .End {
			break
		}
		if t.kind == .Ref {
			target := own
			qualified := t.sheet != ""
			if t.sheet2 != "" {
				// A 3-D reference names a run of sheets by position, which no
				// single row/column anchor can hold. It stays as text, which
				// loses nothing: a 3-D reference does not follow a one-sheet
				// row insert locally either (see `ast_structural`).
				target = -1
			} else if qualified {
				target = book_find(bk, t.sheet)
			} else if prev_kind == .Colon {
				target = prev_target // B5 in Sheet2!A1:B5 is on Sheet2
			}
			if target >= 0 && target < len(ba.keys) {
				rowtok, coltok := "", ""
				good := true
				if t.ref.row != NO_ROW {
					if id, has := axis_id(&ba.rows[target], t.ref.row); has {rowtok = idkey(id)} else {good = false}
				}
				if t.ref.col != NO_COL {
					if id, has := axis_id(&ba.cols[target], t.ref.col); has {coltok = idkey(id)} else {good = false}
				}
				if good {
					strings.write_string(&b, text[last:start])
					flags := strings.builder_make(context.temp_allocator)
					if qualified {strings.write_byte(&flags, 'q')}
					if t.ref.abs_row {strings.write_byte(&flags, 'R')}
					if t.ref.abs_col {strings.write_byte(&flags, 'C')}
					fmt.sbprintf(&b, "%c%s%c%s%c%s%c%s%c", ANCHOR_OPEN, ba.keys[target], ANCHOR_SEP, rowtok, ANCHOR_SEP, coltok, ANCHOR_SEP, strings.to_string(flags), ANCHOR_CLOSE)
					last = lx.i
				}
			}
			prev_target = target
		}
		prev_kind = t.kind
	}
	strings.write_string(&b, text[last:])
	return strings.to_string(b)
}

// render_formula turns anchors back into A1 text against the current axes.
render_formula :: proc(d: ^crdt.Doc, ba: ^Book_Axes, own: int, text: string) -> string {
	if strings.index_byte(text, ANCHOR_OPEN) < 0 {
		return text
	}
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(text) {
		c := text[i]
		if c != ANCHOR_OPEN {
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		end := strings.index_byte(text[i:], ANCHOR_CLOSE)
		if end < 0 {
			strings.write_string(&b, text[i:])
			break
		}
		parts := strings.split(text[i + 1:i + end], "\x02", context.temp_allocator)
		i += end + 1
		if len(parts) != 4 {
			strings.write_string(&b, "#REF!")
			continue
		}
		target := -1
		for k, j in ba.keys {
			if k == parts[0] {target = j}
		}
		ref := Ref {
			row     = NO_ROW,
			col     = NO_COL,
			abs_row = strings.contains(parts[3], "R"),
			abs_col = strings.contains(parts[3], "C"),
		}
		bad := target < 0
		if !bad && parts[1] != "" {
			id, ok := parse_idkey(parts[1])
			r, found := axis_index(&ba.rows[target], id)
			if !ok || !found || r >= MAX_ROWS {bad = true} else {ref.row = r}
		}
		if !bad && parts[2] != "" {
			id, ok := parse_idkey(parts[2])
			cc, found := axis_index(&ba.cols[target], id)
			if !ok || !found || cc >= MAX_COLS {bad = true} else {ref.col = cc}
		}
		if bad {
			strings.write_string(&b, "#REF!")
			continue
		}
		if strings.contains(parts[3], "q") {
			name := crdt.reg_str(d, fmt.tprintf("sh/%s", parts[0]), "name")
			strings.write_string(&b, sheet_prefix(name))
		}
		strings.write_string(&b, ref_text(ref))
	}
	return strings.to_string(b)
}

fmt_text :: proc(f: Cell_Fmt) -> string {
	if fmt_is_default(f) {return ""}
	return fmt.tprintf("%d,%d,%d,%d,%d", int(f.num), int(f.dec), int(f.align), f.bold ? 1 : 0, f.italic ? 1 : 0)
}

fmt_parse :: proc(s: string) -> Cell_Fmt {
	parts := strings.split(s, ",", context.temp_allocator)
	if len(parts) != 5 {return {}}
	n := [5]int{}
	for x, i in parts {n[i], _ = strconv.parse_int(x)}
	return Cell_Fmt {
		num = Num_Format(clamp(n[0], 0, int(max(Num_Format)))),
		dec = u8(clamp(n[1], 0, 9)),
		align = Halign(clamp(n[2], 0, int(max(Halign)))),
		bold = n[3] == 1,
		italic = n[4] == 1,
	}
}

// ---------------------------------------------------------------------------
// Local -> shared
// ---------------------------------------------------------------------------

collab_note_edit :: proc(app: ^App) {
	if !collab.on || collab.pending {return}
	collab.pending = true
	crdt.begin(collab.doc)
}

// collab_note_structural is called by structural_op before it moves cells.
collab_note_structural :: proc(sh: ^Sheet, insert, axis_row: bool, at, n: int) {
	if !collab.on {return}
	append(&collab.structural, Struct_Op{sh, insert, axis_row, at, n})
}

new_sheet_key :: proc() -> string {
	return fmt.aprintf("%08x", rand.uint32())
}

collab_sync :: proc(app: ^App) -> bool {
	if !collab.on || !collab.pending {
		return false
	}
	collab.pending = false
	d := collab.doc
	bk := app.book

	// 1. Row and column insertions and deletions, in the order they happened.
	for op in collab.structural {
		k, ok := collab.keys[op.sheet]
		if !ok {continue}
		key := fmt.tprintf("%s/%s", op.axis_row ? "r" : "k", k)
		if op.insert {
			crdt.insert_virtual(d, key, u64(op.at), u64(op.n))
		} else {
			crdt.remove(d, key, u64(op.at), u64(op.n))
		}
	}
	clear(&collab.structural)

	// 2. The sheets: new ones, gone ones, order, names, panes. The first
	// sheets a workbook ever gets are its bootstrap, not anybody's edit, so
	// they are kept out of undo: undoing the first value typed must not
	// delete the sheet it was typed into.
	bootstrap := len(crdt_sheet_order(d)) == 0
	boot_rec := d.recording
	if bootstrap {d.recording = nil}
	for sh, i in bk.sheets {
		if _, ok := collab.keys[sh]; !ok {
			k := new_sheet_key()
			collab.keys[sh] = k
			order := crdt_sheet_order(d)
			slot := crdt.insert_embed(d, "S", u64(slot_pos(d, order, i)), transmute([]u8)k)
			crdt.set_str(d, fmt.tprintf("sh/%s", k), "slot", idkey(slot))
			// The axes are the sheet's coordinate system, not an edit: undoing
			// the step that added a sheet removes its tab (the slot above), and
			// must never delete its million rows out from under its cells.
			rec := d.recording
			d.recording = nil
			crdt.insert_virtual(d, fmt.tprintf("r/%s", k), 0, MAX_ROWS)
			crdt.insert_virtual(d, fmt.tprintf("k/%s", k), 0, MAX_COLS)
			d.recording = rec
		}
	}
	if bootstrap {d.recording = boot_rec}
	live := make(map[string]bool, 8, context.temp_allocator)
	for sh in bk.sheets {live[collab.keys[sh]] = true}
	for sh, k in collab.keys {
		if !live[k] {
			crdt.set_str(d, fmt.tprintf("sh/%s", k), "gone", "1")
			delete_key(&collab.keys, sh)
		}
	}
	order := crdt_sheet_order(d)
	for sh, i in bk.sheets {
		k := collab.keys[sh]
		if i >= len(order) || order[i] != k {
			// place it again at position i
			slot := crdt.insert_embed(d, "S", u64(slot_pos(d, order, i)), transmute([]u8)k)
			crdt.set_str(d, fmt.tprintf("sh/%s", k), "slot", idkey(slot))
			order = crdt_sheet_order(d)
		}
	}
	ba := read_book_axes(d)
	for sh, si in bk.sheets {
		k := collab.keys[sh]
		owner := fmt.tprintf("sh/%s", k)
		crdt.set_str(d, owner, "name", sh.name)
		set_or_unset(d, owner, "fr", sh.frz_rows == 0 ? "" : fmt.tprintf("%d", sh.frz_rows))
		set_or_unset(d, owner, "fc", sh.frz_cols == 0 ? "" : fmt.tprintf("%d", sh.frz_cols))
		set_or_unset(d, owner, "x", sheet_meta(sh))
		sync_cells(d, bk, si, k, &ba)
	}
	set_or_unset(d, "book", "names", names_json(bk))

	crdt.commit(d)
	if collab.ui.sess != nil {
		client.flush(collab.ui.sess)
	}
	return true
}

// slot_pos is where in "S" a sheet at tab position i goes: before the element
// of the sheet currently at position i, or at the end.
slot_pos :: proc(d: ^crdt.Doc, order: [dynamic]string, i: int) -> int {
	sp := crdt.read_spans(d, "S")
	if i >= len(order) {
		n := 0
		for s in sp.spans {n += int(s.len)}
		return n
	}
	want := order[i]
	pos := 0
	for s in sp.spans {
		if s.kind == .Embed && string(s.content) == want &&
		   crdt.reg_str(d, fmt.tprintf("sh/%s", want), "slot") == idkey(s.first) {
			return pos
		}
		pos += int(s.len)
	}
	return pos
}

set_or_unset :: proc(d: ^crdt.Doc, owner, field, value: string) {
	if value == "" {
		crdt.unset(d, owner, field)
	} else {
		crdt.set_str(d, owner, field, value)
	}
}

sync_cells :: proc(d: ^crdt.Doc, bk: ^Book, si: int, k: string, ba: ^Book_Axes) {
	sh := bk.sheets[si]
	rows, cols := &ba.rows[si], &ba.cols[si]
	// What the CRDT holds for this sheet, by address.
	prefix := fmt.tprintf("c/%s/", k)
	have := make(map[Addr]string, 64, context.temp_allocator) // owner by address
	for owner in d.regs {
		if !strings.has_prefix(owner, prefix) {continue}
		a, ok := owner_addr(owner[len(prefix):], rows, cols)
		if ok {have[a] = owner}
	}
	for a, c in sh.cells {
		rid, ok1 := axis_id(rows, a.row)
		cid, ok2 := axis_id(cols, a.col)
		if !ok1 || !ok2 {continue}
		owner, found := have[a]
		if !found {
			owner = fmt.tprintf("c/%s/%s/%s", k, idkey(rid), idkey(cid))
		}
		delete_key(&have, a)
		set_or_unset(d, owner, "v", anchor_formula(bk, si, ba, c.input))
		set_or_unset(d, owner, "f", fmt_text(c.fmt))
	}
	for _, owner in have {
		crdt.unset(d, owner, "v")
		crdt.unset(d, owner, "f")
	}
	// Column widths and row heights.
	sync_sizes(d, k, "w", sh.col_w, cols)
	sync_sizes(d, k, "h", sh.row_h, rows)
}

owner_addr :: proc(rest: string, rows, cols: ^Axis) -> (Addr, bool) {
	slash := strings.index_byte(rest, '/')
	if slash < 0 {return {}, false}
	rid, ok1 := parse_idkey(rest[:slash])
	cid, ok2 := parse_idkey(rest[slash + 1:])
	if !ok1 || !ok2 {return {}, false}
	r, f1 := axis_index(rows, rid)
	c, f2 := axis_index(cols, cid)
	if !f1 || !f2 || r >= MAX_ROWS || c >= MAX_COLS {return {}, false}
	return Addr{r, c}, true
}

sync_sizes :: proc(d: ^crdt.Doc, k, which: string, sizes: map[int]f32, ax: ^Axis) {
	prefix := fmt.tprintf("%s/%s/", which, k)
	have := make(map[int]string, 8, context.temp_allocator)
	for owner in d.regs {
		if !strings.has_prefix(owner, prefix) {continue}
		id, ok := parse_idkey(owner[len(prefix):])
		if !ok {continue}
		if i, found := axis_index(ax, id); found {have[i] = owner}
	}
	for i, v in sizes {
		owner, found := have[i]
		if !found {
			id, ok := axis_id(ax, i)
			if !ok {continue}
			owner = fmt.tprintf("%s%s", prefix, idkey(id))
		}
		delete_key(&have, i)
		crdt.set_str(d, owner, "s", fmt.tprintf("%.2f", v))
	}
	for _, owner in have {
		crdt.unset(d, owner, "s")
	}
}

Meta_JSON :: struct {
	merges: []string,
	charts: []Chart_JSON,
}

sheet_meta :: proc(sh: ^Sheet) -> string {
	if len(sh.merges) == 0 && len(sh.charts) == 0 {return ""}
	m: Meta_JSON
	merges := make([dynamic]string, 0, len(sh.merges), context.temp_allocator)
	for r in sh.merges {append(&merges, rect_text(r))}
	charts := make([dynamic]Chart_JSON, 0, len(sh.charts), context.temp_allocator)
	for ch in sh.charts {
		append(&charts, Chart_JSON{kind = int(ch.kind), title = ch.title, sheet = ch.sheet, range = rect_text(ch.rect), at = addr_name(ch.at), w = ch.w, h = ch.h})
	}
	m.merges = merges[:]
	m.charts = charts[:]
	data, _ := json.marshal(m, allocator = context.temp_allocator)
	return string(data)
}

names_json :: proc(bk: ^Book) -> string {
	if len(bk.names) == 0 {return ""}
	keys := make([dynamic]string, 0, len(bk.names), context.temp_allocator)
	for k in bk.names {append(&keys, k)}
	slice.sort(keys[:])
	out := make([dynamic]Name_JSON, 0, len(keys), context.temp_allocator)
	for k in keys {
		nd := bk.names[k]
		append(&out, Name_JSON{name = k, sheet = nd.sheet, range = rect_text(nd.rect), abs = nd.abs})
	}
	data, _ := json.marshal(out[:], allocator = context.temp_allocator)
	return string(data)
}

// ---------------------------------------------------------------------------
// Shared -> local
// ---------------------------------------------------------------------------

// shared_json renders the CRDT's workbook in the native file format, which
// is then loaded by the same code that opens a file.
shared_json :: proc(d: ^crdt.Doc, name: string) -> string {
	ba := read_book_axes(d)
	sheets := make([dynamic]Sheet_JSON, 0, len(ba.keys), context.temp_allocator)
	for k, si in ba.keys {
		owner := fmt.tprintf("sh/%s", k)
		sj := Sheet_JSON {
			name = crdt.reg_str(d, owner, "name", fmt.tprintf("Sheet%d", si + 1)),
		}
		sj.frz_row, _ = strconv.parse_int(crdt.reg_str(d, owner, "fr", "0"))
		sj.frz_col, _ = strconv.parse_int(crdt.reg_str(d, owner, "fc", "0"))
		cells := make([dynamic]Cell_JSON, 0, 64, context.temp_allocator)
		prefix := fmt.tprintf("c/%s/", k)
		for cowner in d.regs {
			if !strings.has_prefix(cowner, prefix) {continue}
			a, ok := owner_addr(cowner[len(prefix):], &ba.rows[si], &ba.cols[si])
			if !ok {continue}
			v := crdt.reg_str(d, cowner, "v")
			f := fmt_parse(crdt.reg_str(d, cowner, "f"))
			if v == "" && fmt_is_default(f) {continue}
			append(&cells, Cell_JSON{
				ref = addr_name(a),
				input = render_formula(d, &ba, si, v),
				nfmt = int(f.num),
				dec = int(f.dec),
				align = int(f.align),
				bold = f.bold,
				italic = f.italic,
			})
		}
		sj.cells = cells[:]
		sj.cols = read_sizes(d, k, "w", &ba.cols[si])
		sj.rows = read_sizes(d, k, "h", &ba.rows[si])
		if x := crdt.reg_str(d, owner, "x"); x != "" {
			m: Meta_JSON
			if json.unmarshal(transmute([]u8)x, &m, allocator = context.temp_allocator) == nil {
				sj.merges = m.merges
				sj.charts = m.charts
			}
		}
		append(&sheets, sj)
	}
	names: []Name_JSON
	if nj := crdt.reg_str(d, "book", "names"); nj != "" {
		_ = json.unmarshal(transmute([]u8)nj, &names, allocator = context.temp_allocator)
	}
	doc := Doc_JSON {
		kind    = "palmy.sheets",
		version = DOC_VERSION,
		name    = name,
		sheets  = sheets[:],
		names   = names,
	}
	data, _ := json.marshal(doc, allocator = context.temp_allocator)
	return string(data)
}

read_sizes :: proc(d: ^crdt.Doc, k, which: string, ax: ^Axis) -> []Size_JSON {
	prefix := fmt.tprintf("%s/%s/", which, k)
	out := make([dynamic]Size_JSON, 0, 8, context.temp_allocator)
	for owner in d.regs {
		if !strings.has_prefix(owner, prefix) {continue}
		id, ok := parse_idkey(owner[len(prefix):])
		if !ok {continue}
		i, found := axis_index(ax, id)
		s := crdt.reg_str(d, owner, "s")
		if !found || s == "" {continue}
		v, _ := strconv.parse_f32(s)
		append(&out, Size_JSON{i, v})
	}
	return out[:]
}

cell_anchor :: proc(app: ^App, a: Addr) -> Cell_Anchor {
	k, ok := collab.keys[app.sh]
	if !ok {return {}}
	rows := axis_read(collab.doc, fmt.tprintf("r/%s", k))
	cols := axis_read(collab.doc, fmt.tprintf("k/%s", k))
	r, ok1 := axis_id(&rows, a.row)
	c, ok2 := axis_id(&cols, a.col)
	return Cell_Anchor{strings.clone(k), r, c, ok1 && ok2}
}

anchor_addr :: proc(an: Cell_Anchor, fallback: Addr) -> Addr {
	if !an.ok {return fallback}
	rows := axis_read(collab.doc, fmt.tprintf("r/%s", an.sheet))
	cols := axis_read(collab.doc, fmt.tprintf("k/%s", an.sheet))
	r, f1 := axis_index(&rows, an.row)
	c, f2 := axis_index(&cols, an.col)
	if !f1 || !f2 {return fallback}
	return Addr{min(r, MAX_ROWS - 1), min(c, MAX_COLS - 1)}
}

collab_save_cursor :: proc(app: ^App) {
	delete(collab.saved_cur.sheet)
	delete(collab.saved_anc.sheet)
	collab.saved_cur = cell_anchor(app, app.cur)
	collab.saved_anc = cell_anchor(app, app.anchor)
	collab.saved = true
}

// collab_materialise rebuilds the workbook from the CRDT, keeping the active
// sheet and the cursor on the same cells.
collab_materialise :: proc(app: ^App) {
	active_key := collab.keys[app.sh]
	if !collab.saved {
		collab_save_cursor(app)
	}
	collab.saved = false
	text := shared_json(collab.doc, app.name)
	_, _, _, ok := doc_load_string(app.book.sheets[0], text)
	if !ok {
		return
	}
	clear(&collab.keys)
	order := crdt_sheet_order(collab.doc)
	for sh, i in app.book.sheets {
		if i < len(order) {
			collab.keys[sh] = strings.clone(order[i])
		}
	}
	active := 0
	for k, i in order {
		if k == active_key {active = i}
	}
	app.book.active = clamp(active, 0, len(app.book.sheets) - 1)
	sync_sheet(app)
	app.cur = anchor_addr(collab.saved_cur, app.cur)
	app.anchor = anchor_addr(collab.saved_anc, app.anchor)
	collab.materialised += 1
	collab_refresh_comments(app)
}

collab_init_doc :: proc(app: ^App, d: ^crdt.Doc) {
	collab.doc = d
	collab.keys = make(map[^Sheet]string)
	collab.on = true
}

// collab_undo reverts this window's last change only.
collab_undo :: proc(app: ^App, redo: bool) -> bool {
	ok: bool
	if redo {
		ok = crdt.redo(collab.doc)
	} else {
		_, ok = crdt.undo(collab.doc)
	}
	if !ok {return false}
	if collab.ui.sess != nil {client.flush(collab.ui.sess)}
	collab_materialise(app)
	return true
}

// ---------------------------------------------------------------------------
// Comments on cells
// ---------------------------------------------------------------------------

collab_comment :: proc(app: ^App, text: string) {
	if !collab.on || strings.trim_space(text) == "" {return}
	an := cell_anchor(app, app.cur)
	if !an.ok {return}
	cid := fmt.tprintf("%08x%08x", rand.uint32(), rand.uint32())
	owner := fmt.tprintf("cmt/%s", cid)
	d := collab.doc
	crdt.begin(d)
	crdt.set_str(d, owner, "text", text)
	crdt.set_str(d, owner, "by", collab.ui.handle)
	crdt.set_str(d, owner, "name", collab.ui.name)
	crdt.set_str(d, owner, "color", collab.ui.color)
	crdt.set_str(d, owner, "cell", fmt.tprintf("%s/%s/%s", an.sheet, idkey(an.row), idkey(an.col)))
	crdt.commit(d)
	if collab.ui.sess != nil {client.flush(collab.ui.sess)}
	collab_refresh_comments(app)
}

collab_refresh_comments :: proc(app: ^App) {
	for c in collab.comments {
		delete(c.id)
		delete(c.text)
		delete(c.name)
		delete(c.color)
	}
	clear(&collab.comments)
	if !collab.on {return}
	d := collab.doc
	ba := read_book_axes(d)
	for owner in d.regs {
		if !strings.has_prefix(owner, "cmt/") {continue}
		cell := crdt.reg_str(d, owner, "cell")
		parts := strings.split(cell, "/", context.temp_allocator)
		cc := Cell_Comment {
			id       = strings.clone(owner[4:]),
			text     = strings.clone(crdt.reg_str(d, owner, "text")),
			name     = strings.clone(crdt.reg_str(d, owner, "name")),
			color    = strings.clone(crdt.reg_str(d, owner, "color")),
			resolved = crdt.reg_str(d, owner, "resolved") == "1",
			sheet    = -1,
		}
		if len(parts) == 3 {
			for k, si in ba.keys {
				if k != parts[0] {continue}
				rid, _ := parse_idkey(parts[1])
				cid, _ := parse_idkey(parts[2])
				r, f1 := axis_index(&ba.rows[si], rid)
				c, f2 := axis_index(&ba.cols[si], cid)
				if f1 && f2 {
					cc.sheet = si
					cc.addr = Addr{r, c}
					cc.alive = true
				}
			}
		}
		append(&collab.comments, cc)
	}
}

// ---------------------------------------------------------------------------
// The window: start, tick, presence, drawing
// ---------------------------------------------------------------------------

collab_start :: proc(app: ^App, win: ^p.App, a: collabui.Args) -> string {
	created, err := collabui.start(&collab.ui, "sheet", a, win, app.name, "sheets")
	if err != "" {
		return err
	}
	collab_init_doc(app, collab.ui.sess.doc)
	if created {
		// a new shared workbook starts as whatever this window has open
		collab.pending = true
		crdt.begin(collab.doc)
		collab_sync(app)
	} else {
		collab_materialise(app)
	}
	return ""
}

collab_tick :: proc(ui: ^p.Ctx, app: ^App) {
	if !collab.on || collab.ui.sess == nil || collab.ui.preview {
		return
	}
	s := collab.ui.sess
	if collab.pending {
		if !collabui.may_edit(&collab.ui) {
			collab.pending = false
			clear(&collab.structural)
			crdt.commit(collab.doc)
			collab_materialise(app)
			set_status(app, "View only: you can comment, not edit")
		} else {
			collab_sync(app)
		}
	}
	collab_save_cursor(app)
	ev := client.poll(s)
	if ev.replaced {
		collab.doc = s.doc
	}
	if ev.changed {
		collab_materialise(app)
		if ui != nil {p.redraw(ui)}
	} else {
		collab.saved = false
	}
	if ev.status && s.doc_title != "" && s.doc_title != app.name {
		// the window is named after the shared document, not a file
		delete(app.name)
		app.name = strings.clone(s.doc_title)
	}
	if ev.status || ev.peers || ev.changed {
		collabui.settle(ui)
	}
	// presence: the sheet and the cells this window has selected
	cur := cell_anchor(app, app.cur)
	anc := cell_anchor(app, app.anchor)
	if cur.ok {
		collabui.publish(&collab.ui, fmt.tprintf(`{{"s":"%s","r":"%s","c":"%s","r2":"%s","c2":"%s"}}`, cur.sheet, idkey(cur.row), idkey(cur.col), idkey(anc.row), idkey(anc.col)))
	}
	collabui.keep_token(&collab.ui)
}

// Peer_Cell is one collaborator's selection, resolved into this window.
Peer_Cell :: struct {
	name:  string,
	color: string,
	rect:  Rect_I,
	sheet: int,
}

peer_cells :: proc(app: ^App) -> [dynamic]Peer_Cell {
	out := make([dynamic]Peer_Cell, 0, 4, context.temp_allocator)
	s := collab.ui.sess
	if s == nil || collab.ui.preview {return out}
	ba := read_book_axes(collab.doc)
	for &peer in s.peers {
		k := client.jstr(peer.state, "s")
		for key, si in ba.keys {
			if key != k {continue}
			get :: proc(ax: ^Axis, v: string) -> (int, bool) {
				id, ok := parse_idkey(v)
				if !ok {return 0, false}
				return axis_index(ax, id)
			}
			r, ok1 := get(&ba.rows[si], client.jstr(peer.state, "r"))
			c, ok2 := get(&ba.cols[si], client.jstr(peer.state, "c"))
			r2, ok3 := get(&ba.rows[si], client.jstr(peer.state, "r2"))
			c2, ok4 := get(&ba.cols[si], client.jstr(peer.state, "c2"))
			if !ok1 || !ok2 {continue}
			if !ok3 || !ok4 {r2, c2 = r, c}
			append(&out, Peer_Cell{peer.identity.display_name, peer.identity.color, rect_norm({r, c}, {r2, c2}), si})
		}
	}
	return out
}

// draw_peer_cells outlines everyone else's selection in their colour, with
// their name on a flag above the cell they are on.
draw_peer_cells :: proc(c: ^p.Canvas, app: ^App, g: ^Grid_Geom, body: p.Rect, s: f32) {
	for pc in peer_cells(app) {
		if pc.sheet != app.book.active {continue}
		r0, ok0 := geom_cell(app, g, {pc.rect.r0, pc.rect.c0})
		r1, ok1 := geom_cell(app, g, {pc.rect.r1, pc.rect.c1})
		if !ok0 && !ok1 {continue}
		if !ok0 {r0 = r1}
		if !ok1 {r1 = r0}
		box := p.Rect{r0.x, r0.y, r1.x + r1.w - r0.x, r1.y + r1.h - r0.y}
		col := p.hex(collabui.identity_rgb(pc.color))
		p.push_clip(c, p.rect_intersect(c.clip, body))
		if pc.rect.r0 != pc.rect.r1 || pc.rect.c0 != pc.rect.c1 {
			wash := col
			wash.a = 30
			p.fill_rect(c, box, wash)
		}
		p.stroke_round_rect(c, r0, {0, 0, 0, 0}, max(1.5, 2 * s), col)
		fs := 10.5 * s
		tw := p.text_width(app.fonts, pc.name, fs, .Sans, .Medium)
		fh := fs * 1.6
		p.fill_round_rect(c, {r0.x, r0.y - fh, tw + 8 * s, fh}, {3 * s, 3 * s, 3 * s, 0}, col)
		p.draw_text(c, app.fonts, pc.name, r0.x + 4 * s, r0.y - fh * 0.3, fs, p.hex(0xffffff), .Sans, .Medium)
		p.pop_clip(c)
	}
	// comment markers: a filled triangle in the cell's top-right corner, as
	// every spreadsheet draws them
	for cm in collab.comments {
		if !cm.alive || cm.resolved || cm.sheet != app.book.active {continue}
		r, ok := geom_cell(app, g, cm.addr)
		if !ok {continue}
		k := 9 * s
		col := p.hex(0xf59e0b)
		p.push_clip(c, p.rect_intersect(c.clip, body))
		for i := f32(0); i < k; i += 1 {
			// row i of the triangle runs from the corner leftwards, shrinking
			p.fill_rect(c, {r.x + r.w - (k - i), r.y + i, k - i, 1}, col)
		}
		p.pop_clip(c)
	}
}

collab_panel :: proc(ui: ^p.Ctx, app: ^App) {
	p.col(ui, "w-[300] h-full shrink-0 bg-background border-l border-border overflow-hidden")
	defer p.end(ui)
	switch collab.ui.panel {
	case .History:
		collabui.panel_history(ui, &collab.ui)
	case .Share:
		collabui.panel_share(ui, &collab.ui)
	case .Comments:
		collabui.panel_head(ui, "Comments", "Ctrl+Alt+M comment on the active cell")
		p.col(ui, "w-full flex-1 min-h-0 gap-2 p-3 overflow-hidden")
		if len(collab.comments) == 0 {
			p.text(ui, "No comments yet.", "text-[12] text-muted-foreground")
		}
		for cm in collab.comments {
			p.col(ui, cm.resolved ? "w-full shrink-0 gap-1 p-2.5 rounded-lg border border-border opacity-60" : "w-full shrink-0 gap-1 p-2.5 rounded-lg border border-amber-300")
			p.row(ui, "items-center gap-1.5")
			collabui.monogram(ui, cm.name, cm.color, "size-5")
			p.text(ui, cm.name, "text-[11.5] font-semibold")
			p.spacer(ui)
			if cm.alive && cm.sheet >= 0 && cm.sheet < len(app.book.sheets) {
				p.text(ui, fmt.tprintf("%s!%s", app.book.sheets[cm.sheet].name, addr_name(cm.addr)), "text-[11] font-mono text-muted-foreground")
			} else {
				p.text(ui, "cell deleted", "text-[11] text-muted-foreground")
			}
			p.end(ui)
			p.text(ui, cm.text, "text-[12.5]")
			p.end(ui)
		}
		p.end(ui)
	case .None:
	}
}

// collab_keys handles the collaboration keys; true means the frame's keys
// were used.
collab_keys :: proc(ui: ^p.Ctx, app: ^App) -> bool {
	if !collab.on {return false}
	ca := p.Modifiers{.Ctrl, .Alt}
	if collab.ui.preview {
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			collab_leave_preview(app)
		} else if p.key_pressed(ui, p.KEY_RETURN) {
			collab_restore(app)
		}
		return true
	}
	if p.shortcut(ui, 'c', ca) {
		collab.ui.panel = collab.ui.panel == .Comments ? .None : .Comments
		collab_refresh_comments(app)
		return true
	}
	if p.shortcut(ui, 'm', ca) {
		open_prompt(app, .Comment, "")
		return true
	}
	switch collabui.panel_keys(ui, &collab.ui) {
	case .Handled:
		return true
	case .Preview:
		collab_preview(app, collab.ui.history[clamp(collab.ui.sel, 0, len(collab.ui.history) - 1)].to)
		return true
	case .Add_Person:
		open_prompt(app, .Share, "handle edit")
		return true
	case .Name_Version:
		open_prompt(app, .Name_Version, "")
		return true
	case .None:
	}
	return false
}

collab_preview :: proc(app: ^App, seq: u64) {
	old, err := collabui.state_at(&collab.ui, seq)
	if err != "" {
		set_status(app, "Cannot load that version: %s", err)
		return
	}
	if collab.ui.preview {
		crdt.doc_destroy(collab.doc)
	} else {
		collab.ui.live_doc = collab.doc
	}
	collab.doc = old
	collab.ui.preview = true
	collab.ui.preview_seq = seq
	collab_materialise(app)
	set_status(app, "Read-only. Enter restores this version, Escape returns to now.")
}

collab_leave_preview :: proc(app: ^App) {
	if !collab.ui.preview {return}
	crdt.doc_destroy(collab.doc)
	collab.doc = collab.ui.live_doc
	collab.ui.preview = false
	collab_materialise(app)
}

// collab_restore makes the previewed version current, as a new edit.
collab_restore :: proc(app: ^App) {
	if !collab.ui.preview {return}
	text := shared_json(collab.doc, app.name)
	crdt.doc_destroy(collab.doc)
	collab.doc = collab.ui.live_doc
	collab.ui.preview = false
	collab_materialise(app) // keys for the live sheets
	keys := make(map[int]string, 8, context.temp_allocator)
	for sh, i in app.book.sheets {keys[i] = collab.keys[sh]}
	_, _, _, _ = doc_load_string(app.book.sheets[0], text)
	sync_sheet(app)
	clear(&collab.keys)
	for sh, i in app.book.sheets {
		if k, ok := keys[i]; ok {collab.keys[sh] = k}
	}
	collab.pending = true
	crdt.begin(collab.doc)
	collab_sync(app)
	collab_materialise(app)
	set_status(app, "Restored %s, as a new edit you can undo", collabui.preview_label(&collab.ui))
}
