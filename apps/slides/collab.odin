// Collaborative decks: the deck on the CRDT (cloud/collab/crdt).
//
//	deck                    title, author, theme
//	S                       slide order: a movable list of slide keys
//	sl/<slide>              slot, gone, layout
//	n/<slide>               the speaker notes, as text (merged per character)
//	E/<slide>               the slide's elements in paint order (a movable
//	                        list, so "bring to front" is one placement)
//	el/<elem>               slot, gone, and one register per property —
//	                        x, y, w, h, fill, rotation … — so Alice dragging a
//	                        shape while Bob recolours it keeps both changes
//	t/<elem>                the element's text, merged per character
//
// A move is a new placement plus an LWW pointer to it (Kleppmann 2020), so two
// people moving the same slide at once leave it in exactly one place, and a
// slide moved while another person edits it keeps the edits.
package main

import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:strconv"
import "core:strings"
import p "palmy:."
import client "../../cloud/collab/client"
import crdt "../../cloud/collab/crdt"
import collabui "../../cloud/collab/ui"

Slides_Collab :: struct {
	on:           bool,
	ui:           collabui.State,
	doc:          ^crdt.Doc,
	pending:      bool,
	materialised: int,
}

collab: Slides_Collab

idkey :: proc(id: crdt.ID, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%x.%d", id.agent, id.seq, allocator = allocator)
}

uid_key :: proc(u: u64) -> string {
	return fmt.tprintf("%016x", u)
}

new_uid :: proc() -> u64 {
	return rand.uint64() | 1
}

// movable_order lists the live keys of a movable list, in order.
movable_order :: proc(d: ^crdt.Doc, list, reg_prefix: string) -> [dynamic]string {
	out := make([dynamic]string, 0, 8, context.temp_allocator)
	seen := make(map[string]bool, 8, context.temp_allocator)
	sp := crdt.read_spans(d, list)
	for s in sp.spans {
		if s.kind != .Embed {continue}
		k := string(s.content)
		owner := fmt.tprintf("%s%s", reg_prefix, k)
		if crdt.reg_str(d, owner, "gone") == "1" || crdt.reg_str(d, owner, "slot") != idkey(s.first) || k in seen {
			continue
		}
		seen[k] = true
		append(&out, strings.clone(k, context.temp_allocator))
	}
	return out
}

// place puts key k at position i of a movable list (a new placement, and the
// key's slot pointed at it).
place :: proc(d: ^crdt.Doc, list, reg_prefix, k: string, i: int) {
	order := movable_order(d, list, reg_prefix)
	pos := 0
	sp := crdt.read_spans(d, list)
	if i >= len(order) {
		for s in sp.spans {pos += int(s.len)}
	} else {
		want := order[i]
		for s in sp.spans {
			if s.kind == .Embed && string(s.content) == want &&
			   crdt.reg_str(d, fmt.tprintf("%s%s", reg_prefix, want), "slot") == idkey(s.first) {
				break
			}
			pos += int(s.len)
		}
	}
	slot := crdt.insert_embed(d, list, u64(pos), transmute([]u8)k)
	crdt.set_str(d, fmt.tprintf("%s%s", reg_prefix, k), "slot", idkey(slot))
	crdt.unset(d, fmt.tprintf("%s%s", reg_prefix, k), "gone")
}

// sync_list makes a movable list hold exactly `want`, in that order.
sync_list :: proc(d: ^crdt.Doc, list, reg_prefix: string, want: []string) {
	keep := make(map[string]bool, len(want), context.temp_allocator)
	for k in want {keep[k] = true}
	for k in movable_order(d, list, reg_prefix) {
		if !keep[k] {
			crdt.set_str(d, fmt.tprintf("%s%s", reg_prefix, k), "gone", "1")
		}
	}
	for k, i in want {
		order := movable_order(d, list, reg_prefix)
		if i < len(order) && order[i] == k {continue}
		place(d, list, reg_prefix, k, i)
	}
}

// sync_text writes the difference between a text sequence and `want`.
sync_text :: proc(d: ^crdt.Doc, key, want: string) {
	have := crdt.read_text(d, key)
	if have == want {return}
	pre := 0
	for pre < len(have) && pre < len(want) && have[pre] == want[pre] {pre += 1}
	for pre > 0 && pre < len(want) && want[pre] & 0xc0 == 0x80 {pre -= 1}
	suf := 0
	for suf < len(have) - pre && suf < len(want) - pre && have[len(have) - 1 - suf] == want[len(want) - 1 - suf] {suf += 1}
	if del := len(have) - pre - suf; del > 0 {
		crdt.remove(d, key, u64(pre), u64(del))
	}
	if ins := want[pre:len(want) - suf]; len(ins) > 0 {
		crdt.insert_text(d, key, u64(pre), ins)
	}
}

f3 :: proc(v: f32) -> string {
	return fmt.tprintf("%.3f", v)
}

elem_fields :: proc(e: ^Element) -> [21][2]string {
	return {
		{"kind", fmt.tprintf("%d", int(e.kind))},
		{"x", f3(e.x)},
		{"y", f3(e.y)},
		{"w", f3(e.w)},
		{"h", f3(e.h)},
		{"style", fmt.tprintf("%d", int(e.style))},
		{"ha", fmt.tprintf("%d", int(e.halign))},
		{"va", fmt.tprintf("%d", int(e.valign))},
		{"size", f3(e.size)},
		{"bold", e.bold ? "1" : "0"},
		{"color", fmt.tprintf("%x", e.color)},
		{"fill", fmt.tprintf("%x", e.fill)},
		{"fa", f3(e.fill_a)},
		{"stroke", fmt.tprintf("%x", e.stroke)},
		{"sw", f3(e.stroke_w)},
		{"rad", f3(e.radius)},
		{"head", f3(e.head)},
		{"op", f3(e.opacity)},
		{"rot", f3(e.rotation)},
		{"src", e.src},
		{"runs", runs_encode(e.runs)},
	}
}

// runs_encode spells a run list as one register value: `start,end,flags,
// colour,size` per run, `;` between runs, flags 1 bold and 2 italic. A run's
// offsets are bytes into the element's text, which is a separate CRDT text;
// two people editing the same box's words concurrently can therefore leave a
// run a few bytes off its word. runs_decode clamps, so that is a cosmetic
// shift and never an out-of-range read.
runs_encode :: proc(runs: []Run) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r, i in runs {
		if i > 0 {
			strings.write_byte(&b, ';')
		}
		fl := (r.bold ? 1 : 0) | (r.italic ? 2 : 0)
		fmt.sbprintf(&b, "%d,%d,%d,%x,%s", r.start, r.end, fl, r.color, f3(r.size))
	}
	return strings.to_string(b)
}

runs_decode :: proc(s: string, text_len: int) -> []Run {
	if s == "" {
		return nil
	}
	out := make([dynamic]Run, context.temp_allocator)
	for part in strings.split(s, ";", context.temp_allocator) {
		f := strings.split(part, ",", context.temp_allocator)
		if len(f) != 5 {
			continue
		}
		a, _ := strconv.parse_int(f[0])
		b, _ := strconv.parse_int(f[1])
		fl, _ := strconv.parse_int(f[2])
		c, _ := strconv.parse_u64_of_base(f[3], 16)
		z, _ := strconv.parse_f32(f[4])
		append(&out, Run{start = a, end = b, bold = fl & 1 != 0, italic = fl & 2 != 0, color = u32(c), size = z})
	}
	return runs_clean(out[:], text_len)
}

collab_note_edit :: proc() {
	if !collab.on || collab.pending {return}
	collab.pending = true
	crdt.begin(collab.doc)
}

// ensure_uids gives every slide and element an identity, and a fresh one to
// a duplicate (a pasted or duplicated element copies its original's).
ensure_uids :: proc(d: ^Deck) {
	seen := make(map[u64]bool, 64, context.temp_allocator)
	for &s in d.slides {
		if s.uid == 0 || s.uid in seen {s.uid = new_uid()}
		seen[s.uid] = true
		for &e in s.elems {
			if e.uid == 0 || e.uid in seen {e.uid = new_uid()}
			seen[e.uid] = true
		}
	}
}

collab_sync :: proc(st: ^St) -> bool {
	if !collab.on || !collab.pending {return false}
	collab.pending = false
	d := collab.doc
	if st.mode == .Text {
		if e := cur_elem(st); e != nil {commit_text(st, e)}
	}
	ensure_uids(&st.deck)

	crdt.set_str(d, "deck", "title", st.deck.title)
	crdt.set_str(d, "deck", "author", st.deck.author)
	crdt.set_str(d, "deck", "theme", st.deck.theme.name)

	keys := make([dynamic]string, 0, len(st.deck.slides), context.temp_allocator)
	for &s in st.deck.slides {append(&keys, uid_key(s.uid))}
	sync_list(d, "S", "sl/", keys[:])
	for &s in st.deck.slides {
		sk := uid_key(s.uid)
		owner := fmt.tprintf("sl/%s", sk)
		crdt.set_str(d, owner, "layout", fmt.tprintf("%d", int(s.layout)))
		crdt.set_str(d, owner, "tr", fmt.tprintf("%d,%d", int(s.transition), s.transition_ms))
		sync_text(d, fmt.tprintf("n/%s", sk), s.notes)
		ekeys := make([dynamic]string, 0, len(s.elems), context.temp_allocator)
		for &e in s.elems {append(&ekeys, uid_key(e.uid))}
		sync_list(d, fmt.tprintf("E/%s", sk), "el/", ekeys[:])
		for &e in s.elems {
			ek := uid_key(e.uid)
			eo := fmt.tprintf("el/%s", ek)
			for kv in elem_fields(&e) {
				crdt.set_str(d, eo, kv[0], kv[1])
			}
			sync_text(d, fmt.tprintf("t/%s", ek), e.text)
		}
	}
	crdt.commit(d)
	if collab.ui.sess != nil {client.flush(collab.ui.sess)}
	return true
}

// collab_deck builds a deck from the CRDT.
collab_deck :: proc(d: ^crdt.Doc, base: ^Deck) -> Deck {
	out := Deck {
		version = base.version,
		title   = strings.clone(crdt.reg_str(d, "deck", "title", base.title)),
		author  = strings.clone(crdt.reg_str(d, "deck", "author", base.author)),
		theme   = base.theme,
		slides  = make([dynamic]Slide),
	}
	tname := crdt.reg_str(d, "deck", "theme", base.theme.name)
	for th in THEMES {
		if th.name == tname {out.theme = th}
	}
	for sk in movable_order(d, "S", "sl/") {
		s := Slide {
			elems = make([dynamic]Element),
		}
		s.uid, _ = strconv.parse_u64_of_base(sk, 16)
		lv, _ := strconv.parse_int(crdt.reg_str(d, fmt.tprintf("sl/%s", sk), "layout", "0"))
		s.layout = Layout(clamp(lv, 0, int(max(Layout))))
		if tr := strings.split(crdt.reg_str(d, fmt.tprintf("sl/%s", sk), "tr", "0,0"), ",", context.temp_allocator); len(tr) == 2 {
			tv, _ := strconv.parse_int(tr[0])
			s.transition = Transition(clamp(tv, 0, int(max(Transition))))
			s.transition_ms, _ = strconv.parse_int(tr[1])
		}
		s.notes = strings.clone(crdt.read_text(d, fmt.tprintf("n/%s", sk)))
		for ek in movable_order(d, fmt.tprintf("E/%s", sk), "el/") {
			eo := fmt.tprintf("el/%s", ek)
			gi :: proc(d: ^crdt.Doc, o, f: string) -> int {
				v, _ := strconv.parse_int(crdt.reg_str(d, o, f, "0"))
				return v
			}
			gf :: proc(d: ^crdt.Doc, o, f: string) -> f32 {
				v, _ := strconv.parse_f32(crdt.reg_str(d, o, f, "0"))
				return v
			}
			gx :: proc(d: ^crdt.Doc, o, f: string) -> u32 {
				v, _ := strconv.parse_u64_of_base(crdt.reg_str(d, o, f, "0"), 16)
				return u32(v)
			}
			e := Element {
				kind     = Kind(clamp(gi(d, eo, "kind"), 0, int(max(Kind)))),
				x        = gf(d, eo, "x"),
				y        = gf(d, eo, "y"),
				w        = gf(d, eo, "w"),
				h        = gf(d, eo, "h"),
				style    = Style(clamp(gi(d, eo, "style"), 0, int(max(Style)))),
				halign   = Halign(clamp(gi(d, eo, "ha"), 0, int(max(Halign)))),
				valign   = Valign(clamp(gi(d, eo, "va"), 0, int(max(Valign)))),
				size     = gf(d, eo, "size"),
				bold     = crdt.reg_str(d, eo, "bold") == "1",
				color    = gx(d, eo, "color"),
				fill     = gx(d, eo, "fill"),
				fill_a   = gf(d, eo, "fa"),
				stroke   = gx(d, eo, "stroke"),
				stroke_w = gf(d, eo, "sw"),
				radius   = gf(d, eo, "rad"),
				head     = gf(d, eo, "head"),
				opacity  = gf(d, eo, "op"),
				rotation = gf(d, eo, "rot"),
				src      = strings.clone(crdt.reg_str(d, eo, "src")),
				text     = strings.clone(crdt.read_text(d, fmt.tprintf("t/%s", ek))),
			}
			e.runs = runs_decode(crdt.reg_str(d, eo, "runs"), len(e.text))
			e.uid, _ = strconv.parse_u64_of_base(ek, 16)
			append(&s.elems, e)
		}
		append(&out.slides, s)
	}
	if len(out.slides) == 0 {
		append(&out.slides, slide_make(.Blank))
	}
	return out
}

// collab_materialise rebuilds the deck, keeping the current slide and the
// selected element by identity.
collab_materialise :: proc(st: ^St) {
	cur_uid: u64
	sel_uid: u64
	if st.slide >= 0 && st.slide < len(st.deck.slides) {
		cur_uid = st.deck.slides[st.slide].uid
		if st.sel >= 0 && st.sel < len(st.deck.slides[st.slide].elems) {
			sel_uid = st.deck.slides[st.slide].elems[st.sel].uid
		}
	}
	nd := collab_deck(collab.doc, &st.deck)
	deck_free(&st.deck)
	st.deck = nd
	st.sel = -1
	for &s, i in st.deck.slides {
		if s.uid == cur_uid {
			st.slide = i
			for &e, j in s.elems {
				if e.uid == sel_uid {st.sel = j}
			}
		}
	}
	st.slide = clamp(st.slide, 0, len(st.deck.slides) - 1)
	collab.materialised += 1
}

collab_undo :: proc(st: ^St, redo: bool) -> bool {
	ok: bool
	if redo {
		ok = crdt.redo(collab.doc)
	} else {
		_, ok = crdt.undo(collab.doc)
	}
	if !ok {return false}
	if collab.ui.sess != nil {client.flush(collab.ui.sess)}
	collab_materialise(st)
	return true
}

// ---------------------------------------------------------------------------
// The window
// ---------------------------------------------------------------------------

collab_start :: proc(st: ^St, win: ^p.App, a: collabui.Args) -> string {
	created, err := collabui.start(&collab.ui, "deck", a, win, st.deck.title, "slides")
	if err != "" {return err}
	collab.doc = collab.ui.sess.doc
	collab.on = true
	if created {
		collab.pending = true
		crdt.begin(collab.doc)
		collab_sync(st)
	} else {
		collab_materialise(st)
	}
	return ""
}

collab_tick :: proc(ui: ^p.Ctx, st: ^St) {
	if !collab.on || collab.ui.sess == nil || collab.ui.preview {return}
	s := collab.ui.sess
	// Text being typed into a box is committed into the model as it goes, so
	// it is shared as it goes; a frame in text mode always counts as an edit.
	if (st.mode == .Text || st.mode == .Notes) && collabui.may_edit(&collab.ui) {
		collab_note_edit()
	}
	if collab.pending {
		if !collabui.may_edit(&collab.ui) {
			collab.pending = false
			crdt.commit(collab.doc)
			collab_materialise(st)
		} else {
			collab_sync(st)
		}
	}
	ev := client.poll(s)
	if ev.replaced {collab.doc = s.doc}
	if ev.changed {
		if st.mode == .Text {
			// keep the box being typed into in sync with the caret
			if e := cur_elem(st); e != nil {commit_text(st, e)}
		}
		editing := st.mode == .Text
		caret := st.ed.caret
		collab_materialise(st)
		if editing {
			if e := cur_elem(st); e != nil {
				ed_begin(st, e.text)
				st.ed.caret = min(caret, len(st.ed.buf))
				st.ed.anchor = st.ed.caret
			} else {
				st.mode = .Browse
			}
		}
		st.dirty = true
		if ui != nil {p.redraw(ui)}
	}
	if ev.status || ev.peers || ev.changed {collabui.settle(ui)}
	sk, ek := "", ""
	if st.slide >= 0 && st.slide < len(st.deck.slides) {
		sl := &st.deck.slides[st.slide]
		sk = uid_key(sl.uid)
		if st.sel >= 0 && st.sel < len(sl.elems) {ek = uid_key(sl.elems[st.sel].uid)}
	}
	collabui.publish(&collab.ui, fmt.tprintf(`{{"s":"%s","e":"%s","t":%s}}`, sk, ek, st.mode == .Text ? "true" : "false"))
	collabui.keep_token(&collab.ui)
}

Peer_Mark :: struct {
	name:   string,
	color:  string,
	slide:  int,
	elem:   int,
	typing: bool,
}

peer_marks :: proc(st: ^St) -> [dynamic]Peer_Mark {
	out := make([dynamic]Peer_Mark, 0, 4, context.temp_allocator)
	s := collab.ui.sess
	if !collab.on || s == nil || collab.ui.preview {return out}
	for &peer in s.peers {
		sk := client.jstr(peer.state, "s")
		ek := client.jstr(peer.state, "e")
		pm := Peer_Mark{peer.identity.display_name, peer.identity.color, -1, -1, false}
		if obj, ok := peer.state.(json.Object); ok {
			if b, ok2 := obj["t"].(json.Boolean); ok2 {pm.typing = bool(b)}
		}
		for &sl, i in st.deck.slides {
			if uid_key(sl.uid) != sk {continue}
			pm.slide = i
			for &e, j in sl.elems {
				if uid_key(e.uid) == ek {pm.elem = j}
			}
		}
		append(&out, pm)
	}
	return out
}

// draw_peer_marks outlines the element each collaborator has selected, with
// their name on a flag.
draw_peer_marks :: proc(c: ^p.Canvas, slide: p.Rect, st: ^St) {
	k := slide.w / SLIDE_W
	for pm in peer_marks(st) {
		if pm.slide != st.slide || pm.elem < 0 {continue}
		e := &st.deck.slides[pm.slide].elems[pm.elem]
		box := p.Rect{slide.x + e.x * k, slide.y + e.y * k, e.w * k, e.h * k}
		col := p.hex(collabui.identity_rgb(pm.color))
		p.stroke_round_rect(c, p.rect_inset(box, -4 * c.scale), {4, 4, 4, 4}, max(1.5, 2 * c.scale), col)
		label := pm.typing ? fmt.tprintf("%s · typing", pm.name) : pm.name
		fs := 11 * c.scale
		tw := p.text_width(st.fonts, label, fs, .Sans, .Medium)
		fh := fs * 1.6
		p.fill_round_rect(c, {box.x - 4 * c.scale, box.y - 4 * c.scale - fh, tw + 10 * c.scale, fh}, {3, 3, 3, 0}, col)
		p.draw_text(c, st.fonts, label, box.x + 1 * c.scale, box.y - 4 * c.scale - fh * 0.3, fs, p.hex(0xffffff), .Sans, .Medium)
	}
}

collab_keys :: proc(ui: ^p.Ctx, st: ^St) -> bool {
	if !collab.on {return false}
	if collab.ui.preview {
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			collab_leave_preview(st)
		} else if p.key_pressed(ui, p.KEY_RETURN) {
			collab_restore(st)
		}
		return true
	}
	switch collabui.panel_keys(ui, &collab.ui) {
	case .Handled:
		return true
	case .Preview:
		collab_preview(st, collab.ui.history[clamp(collab.ui.sel, 0, len(collab.ui.history) - 1)].to)
		return true
	case .Add_Person, .Name_Version:
		return true
	case .None:
	}
	return false
}

collab_preview :: proc(st: ^St, seq: u64) {
	old, err := collabui.state_at(&collab.ui, seq)
	if err != "" {return}
	if collab.ui.preview {
		crdt.doc_destroy(collab.doc)
	} else {
		collab.ui.live_doc = collab.doc
	}
	collab.doc = old
	collab.ui.preview = true
	collab.ui.preview_seq = seq
	collab_materialise(st)
}

collab_leave_preview :: proc(st: ^St) {
	if !collab.ui.preview {return}
	crdt.doc_destroy(collab.doc)
	collab.doc = collab.ui.live_doc
	collab.ui.preview = false
	collab_materialise(st)
}

collab_restore :: proc(st: ^St) {
	if !collab.ui.preview {return}
	crdt.doc_destroy(collab.doc)
	collab.doc = collab.ui.live_doc
	collab.ui.preview = false
	// st.deck holds the old version, uids and all: write it as a new edit
	collab.pending = true
	crdt.begin(collab.doc)
	collab_sync(st)
	collab_materialise(st)
}

collab_panel :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-[300] h-full shrink-0 bg-background border-l border-border overflow-hidden")
	defer p.end(ui)
	#partial switch collab.ui.panel {
	case .History:
		collabui.panel_history(ui, &collab.ui)
	case .Share:
		collabui.panel_share(ui, &collab.ui)
	}
}
