package main

// Conversations: renaming one, and finding one again.
//
// A conversation lives in the identity's cloud (assistant_conversations,
// assistant_messages), so both go through the identity's own session and
// RLS, and both filter by identity_id as well: a conversation id learned
// from another identity matches nothing, and a search sees only this
// identity's conversations. That is the same rule as everything else the
// assistant touches, and e2e.sh's section G asserts it across identities.
//
// Search is a substring match, case-insensitive, over the title and over
// every message (what the person asked, what the assistant answered, the
// tool lines and notices), not a ranked search: a conversation is found by
// a phrase remembered from it. Title matches come first, then conversations
// that matched only in a message, each newest first, with the line that
// matched.

import "core:fmt"
import "core:strings"
import ck "../cloudkit"

TITLE_MAX :: 200 // the column's check constraint

// title_clean is what a rename stores: one line, trimmed, at most TITLE_MAX
// characters (cut on a rune boundary). "" means there was nothing to store.
title_clean :: proc(s: string, allocator := context.allocator) -> string {
	t := strings.trim_space(s)
	if nl := strings.index_any(t, "\r\n"); nl >= 0 {t = strings.trim_space(t[:nl])}
	n, cut := 0, len(t)
	for _, i in t {
		if n == TITLE_MAX {cut = i; break}
		n += 1
	}
	return strings.clone(t[:cut], allocator)
}

// like_value turns what the person typed into a PostgREST `ilike` value that
// matches it literally anywhere: LIKE's own wildcards and its escape are
// escaped, PostgREST's `*` (its stand-in for %) is dropped, and the result
// is percent-encoded for the query string.
like_value :: proc(q: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '*')
	for c in transmute([]u8)q {
		switch c {
		case '\\', '%', '_':
			strings.write_byte(&b, '\\')
			strings.write_byte(&b, c)
		case '*':
		case:
			strings.write_byte(&b, c)
		}
	}
	strings.write_byte(&b, '*')
	return ck.escape(strings.to_string(b), allocator = allocator)
}

// fold_index is strings.index, ignoring ASCII case.
fold_index :: proc(s, sub: string) -> int {
	if len(sub) == 0 {return 0}
	low :: proc(c: u8) -> u8 {return c >= 'A' && c <= 'Z' ? c + 32 : c}
	outer: for i := 0; i + len(sub) <= len(s); i += 1 {
		for j in 0 ..< len(sub) {
			if low(s[i + j]) != low(sub[j]) {continue outer}
		}
		return i
	}
	return -1
}

// snippet_around is the part of `text` around the first match of `q`: one
// line, at most `width` bytes either side, cut on rune boundaries, with an
// ellipsis where it was cut.
snippet_around :: proc(text, q: string, width := 48, allocator := context.allocator) -> string {
	flat, _ := strings.replace_all(text, "\n", " ", context.temp_allocator)
	at := fold_index(flat, q)
	if at < 0 {at = 0}
	lo := max(0, at - width)
	hi := min(len(flat), at + len(q) + width)
	for lo > 0 && flat[lo] & 0xc0 == 0x80 {lo -= 1}
	for hi < len(flat) && flat[hi] & 0xc0 == 0x80 {hi += 1}
	return fmt.aprintf("%s%s%s", lo > 0 ? "…" : "", strings.trim_space(flat[lo:hi]), hi < len(flat) ? "…" : "", allocator = allocator)
}

// conv_rename sets one conversation's title. A conversation of another
// identity, or one that does not exist, is "not found" — the same answer,
// so a rename cannot be used to learn which ids exist elsewhere.
conv_rename :: proc(c: ^ck.Client, ident: ck.Identity, id, title: string) -> (stored: string, err: string, not_found: bool) {
	t := title_clean(title, context.temp_allocator)
	if t == "" {return "", "a title needs at least one character", false}
	if !uuid_like(id) {return "", "no such conversation in this identity", true}
	o := ck.obj()
	// Not updated_at: a rename is not activity, and the list stays in the
	// order the conversations were last used.
	ck.put(&o, "title", t)
	rows, e := ck.update(c, "assistant_conversations", fmt.tprintf("id=eq.%s&identity_id=eq.%s", id, ident.id), ck.obj_done(&o), context.temp_allocator)
	if !ck.ok(e) {return "", strings.clone(e.message), false}
	if len(ck.array(rows)) == 0 {return "", "no such conversation in this identity", true}
	return strings.clone(ck.get_str(ck.array(rows)[0], "title")), "", false
}

// uuid_like keeps anything but an id out of a PostgREST filter.
uuid_like :: proc(s: string) -> bool {
	if len(s) != 36 {return false}
	for c, i in transmute([]u8)s {
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {return false}
		case:
			if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {return false}
		}
	}
	return true
}

Conv_Hit :: struct {
	id, title, updated: string,
	in_title:           bool, // the title matched; otherwise a message did
	role:               string, // the matching message's, when a message matched
	snippet:            string,
}

// conv_search finds this identity's conversations whose title or messages
// contain `q`.
conv_search :: proc(c: ^ck.Client, ident: ck.Identity, q: string, limit := 50, allocator := context.allocator) -> (hits: [dynamic]Conv_Hit, err: string) {
	hits = make([dynamic]Conv_Hit, allocator)
	q := strings.trim_space(q)
	if q == "" {return hits, "nothing to search for"}
	pat := like_value(q)
	seen := make(map[string]bool, allocator = context.temp_allocator)

	tv, te := ck.select(c, "assistant_conversations", fmt.tprintf("select=id,title,updated_at&identity_id=eq.%s&title=ilike.%s&order=updated_at.desc&limit=%d", ident.id, pat, limit), context.temp_allocator)
	if !ck.ok(te) {return hits, strings.clone(te.message, allocator)}
	for r in ck.array(tv) {
		id := ck.get_str(r, "id")
		seen[id] = true
		append(&hits, Conv_Hit{
			id = strings.clone(id, allocator),
			title = strings.clone(ck.get_str(r, "title"), allocator),
			updated = strings.clone(ck.get_str(r, "updated_at"), allocator),
			in_title = true,
			snippet = strings.clone(ck.get_str(r, "title"), allocator),
		})
	}

	mv, me := ck.select(c, "assistant_messages", fmt.tprintf("select=conversation_id,role,content&identity_id=eq.%s&content=ilike.%s&order=created_at.desc&limit=400", ident.id, pat), context.temp_allocator)
	if !ck.ok(me) {return hits, strings.clone(me.message, allocator)}
	first := make(map[string]ck.Value, allocator = context.temp_allocator)
	order := make([dynamic]string, context.temp_allocator)
	for r in ck.array(mv) {
		id := ck.get_str(r, "conversation_id")
		if seen[id] || id in first {continue}
		first[id] = r
		append(&order, id)
	}
	if len(order) == 0 {return hits, ""}
	ids := strings.join(order[:], ",", context.temp_allocator)
	cv, ce := ck.select(c, "assistant_conversations", fmt.tprintf("select=id,title,updated_at&identity_id=eq.%s&id=in.(%s)&order=updated_at.desc", ident.id, ids), context.temp_allocator)
	if !ck.ok(ce) {return hits, strings.clone(ce.message, allocator)}
	for r in ck.array(cv) {
		if len(hits) >= limit {break}
		id := ck.get_str(r, "id")
		m := first[id]
		append(&hits, Conv_Hit{
			id = strings.clone(id, allocator),
			title = strings.clone(ck.get_str(r, "title"), allocator),
			updated = strings.clone(ck.get_str(r, "updated_at"), allocator),
			role = strings.clone(ck.get_str(m, "role"), allocator),
			snippet = snippet_around(ck.get_str(m, "content"), q, allocator = allocator),
		})
	}
	return hits, ""
}
