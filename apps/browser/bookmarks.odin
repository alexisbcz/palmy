// Bookmarks, stored in a shape designed to sync.
//
// Nothing here talks to a server yet. What it does is make the local file
// mergeable with any other copy of itself, so that the day a sync client
// exists (apps/cloudkit, browser_bookmarks in cloud/supabase) it is a
// transport and nothing more. Four decisions carry that:
//
// 1. **Stable ids.** Every bookmark, folder and separator has a random UUID
//    from the moment it exists. Titles and URLs are not identity: two
//    bookmarks of the same page are two bookmarks, and renaming one is an
//    edit, not a delete and an add. The two roots have fixed, well-known
//    UUIDs so every device agrees which folder is the toolbar.
//
// 2. **Per-field clocks, last writer wins per field group.** A record carries
//    three hybrid logical clocks: `content_clock` (title, url), `place_clock`
//    (parent, position) and `life_clock` (deleted). Merging two copies of a
//    record keeps, for each group independently, the side with the larger
//    clock. So renaming a bookmark on the laptop while moving it on the phone
//    keeps both changes, which a single per-record timestamp would not.
//    A clock is `<ms:13 digits>-<counter:4 hex>-<device>`: it sorts as a
//    string, the counter keeps one device's writes in order within a
//    millisecond even if its wall clock steps back, and the device id breaks
//    ties so every replica picks the same winner.
//
// 3. **Tombstones, not deletion.** Deleting sets `deleted` with a new
//    life_clock and keeps the record, so the delete propagates instead of the
//    other device's copy resurrecting it. A delete loses to a later edit of
//    the same group only through its own clock -- undelete is just a newer
//    life_clock with deleted=false.
//
// 4. **Fractional positions.** Order among siblings is a string key between
//    its neighbours' keys (base 62), not an index. Inserting between two
//    bookmarks writes one record, not a renumbering of every sibling, so two
//    devices inserting into the same folder concurrently both keep their
//    insert. Equal keys (possible after a concurrent insert at the same spot)
//    fall back to the id, so the order is the same everywhere.
//
// Two rules apply after any merge, and are applied when the tree is read
// rather than by rewriting records, so they need no clock of their own: a
// record whose parent is missing or deleted moves to Other Bookmarks if its
// own place_clock is newer than the parent's deletion (it was moved there
// after the folder was deleted elsewhere) and is hidden with the folder
// otherwise; and a cycle created by two concurrent moves is broken at the
// record with the older place_clock, which is shown under Other Bookmarks.
package browser

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:os"

ROOT_TOOLBAR :: "00000000-0000-4000-8000-000000000001"
ROOT_OTHER :: "00000000-0000-4000-8000-000000000002"

BOOKMARKS_FORMAT :: 1

Bookmark :: struct {
	id:            string `json:"id"`,
	kind:          string `json:"kind"`, // "bookmark", "folder", "separator"
	parent:        string `json:"parent"`,
	position:      string `json:"position"`,
	title:         string `json:"title"`,
	url:           string `json:"url"`,
	created:       i64 `json:"created"`, // ms since the epoch
	deleted:       bool `json:"deleted"`,
	content_clock: string `json:"content_clock"`,
	place_clock:   string `json:"place_clock"`,
	life_clock:    string `json:"life_clock"`,
}

Bookmark_File :: struct {
	format:          int `json:"format"`,
	// the largest clock this file has pushed to the account; everything with
	// a newer clock is waiting to be sent
	pushed_through:  string `json:"pushed_through"`,
	// the largest server change counter pulled so far
	pulled_seq:      i64 `json:"pulled_seq"`,
	items:           [dynamic]Bookmark `json:"items"`,
}

Hlc :: struct {
	ms:      i64,
	counter: u32,
	device:  string,
}

Bookmarks :: struct {
	path:   string,
	file:   Bookmark_File,
	clock:  Hlc,
	dirty:  bool,
}

// ---------------------------------------------------------------------------
// Clocks
// ---------------------------------------------------------------------------

hlc_text :: proc(h: Hlc, allocator := context.allocator) -> string {
	return fmt.aprintf("%013d-%04x-%s", h.ms, h.counter, h.device, allocator = allocator)
}

hlc_parse :: proc(s: string) -> (h: Hlc, ok: bool) {
	if len(s) < 19 || s[13] != '-' || s[18] != '-' {
		return {}, false
	}
	for c in s[:13] {
		if c < '0' || c > '9' {
			return {}, false
		}
		h.ms = h.ms * 10 + i64(c - '0')
	}
	for c in s[14:18] {
		d: u32
		switch c {
		case '0' ..= '9':
			d = u32(c - '0')
		case 'a' ..= 'f':
			d = u32(c - 'a' + 10)
		case:
			return {}, false
		}
		h.counter = h.counter * 16 + d
	}
	h.device = s[19:]
	return h, true
}

// tick advances this replica's clock for a local write.
tick :: proc(b: ^Bookmarks, allocator := context.allocator) -> string {
	now := now_ms()
	if now > b.clock.ms {
		b.clock.ms = now
		b.clock.counter = 0
	} else {
		b.clock.counter += 1
	}
	return hlc_text(b.clock, allocator)
}

// observe moves the clock past a clock seen from elsewhere, so the next local
// write sorts after everything this replica has already seen.
observe :: proc(b: ^Bookmarks, clock: string) {
	h, ok := hlc_parse(clock)
	if !ok {
		return
	}
	if h.ms > b.clock.ms || (h.ms == b.clock.ms && h.counter > b.clock.counter) {
		b.clock.ms = h.ms
		b.clock.counter = h.counter
	}
}

clock_max :: proc(a, b: string) -> string {
	return a >= b ? a : b
}

record_clock :: proc(r: ^Bookmark) -> string {
	return clock_max(clock_max(r.content_clock, r.place_clock), r.life_clock)
}

// ---------------------------------------------------------------------------
// Fractional positions
// ---------------------------------------------------------------------------

DIGITS := "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

@(private = "file")
digit_of :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'A' ..= 'Z':
		return int(c - 'A') + 10
	case 'a' ..= 'z':
		return int(c - 'a') + 36
	}
	return 0
}

// key_between returns a key strictly between a and b, where "" means the
// start (for a) or the end (for b). Keys never end in '0', which is what
// guarantees there is always room for another one.
key_between :: proc(a, b: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	midpoint(&sb, a, b)
	return strings.to_string(sb)
}

@(private = "file")
midpoint :: proc(sb: ^strings.Builder, a, b: string) {
	if b != "" {
		// skip the common prefix, reading a as padded with zeros
		n := 0
		for n < len(b) {
			ca := n < len(a) ? a[n] : '0'
			if ca != b[n] {
				break
			}
			n += 1
		}
		if n > 0 {
			strings.write_string(sb, b[:n])
			midpoint(sb, n < len(a) ? a[n:] : "", b[n:])
			return
		}
	}
	da := a != "" ? digit_of(a[0]) : 0
	db := b != "" ? digit_of(b[0]) : 62
	if db - da > 1 {
		strings.write_byte(sb, DIGITS[(da + db) / 2])
		return
	}
	if b != "" && len(b) > 1 {
		strings.write_byte(sb, b[0])
		return
	}
	strings.write_byte(sb, DIGITS[da])
	midpoint(sb, len(a) > 1 ? a[1:] : "", "")
}

// ---------------------------------------------------------------------------
// Loading and saving
// ---------------------------------------------------------------------------

bookmarks_open :: proc(path: string, device: string) -> Bookmarks {
	b := Bookmarks {
		path = strings.clone(path),
	}
	b.clock.device = strings.clone(device)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err == nil {
		if json.unmarshal(data, &b.file) != nil {
			// A file that will not parse is kept, not overwritten: rename it
			// aside so the person's bookmarks are recoverable by hand.
			os.rename(path, fmt.tprintf("%s.unreadable-%d", path, now_ms()))
			b.file = {}
		}
	}
	b.file.format = BOOKMARKS_FORMAT
	for &r in b.file.items {
		observe(&b, record_clock(&r))
	}
	ensure_roots(&b)
	return b
}

bookmarks_save :: proc(b: ^Bookmarks) -> bool {
	data, err := json.marshal(b.file, {pretty = true, use_spaces = true, spaces = 1}, context.temp_allocator)
	if err != nil {
		return false
	}
	ok := write_atomic(b.path, data)
	if ok {
		b.dirty = false
	}
	return ok
}

@(private = "file")
ensure_roots :: proc(b: ^Bookmarks) {
	roots := [2]struct {
		id, title, pos: string,
	}{{ROOT_TOOLBAR, "Bookmarks bar", "V"}, {ROOT_OTHER, "Other bookmarks", "k"}}
	for root in roots {
		if find(b, root.id) == nil {
			// The roots carry the epoch as their clock: any real edit of a
			// root (a rename) beats this default on every device.
			zero := "0000000000000-0000-root"
			append(
				&b.file.items,
				Bookmark {
					id = root.id,
					kind = "folder",
					parent = "",
					position = root.pos,
					title = root.title,
					content_clock = zero,
					place_clock = zero,
					life_clock = zero,
				},
			)
		}
	}
}

find :: proc(b: ^Bookmarks, id: string) -> ^Bookmark {
	for &r in b.file.items {
		if r.id == id {
			return &r
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Local edits. Each one ticks the clock for exactly the groups it touches.
// ---------------------------------------------------------------------------

bookmark_add :: proc(b: ^Bookmarks, parent, title, url: string, kind := "bookmark", after := "") -> ^Bookmark {
	par := parent
	if p := find(b, par); p == nil || p.kind != "folder" || p.deleted {
		par = ROOT_OTHER
	}
	kids := children(b, par, context.temp_allocator)
	lo, hi := "", ""
	if after == "" {
		if len(kids) > 0 {
			lo = kids[len(kids) - 1].position
		}
	} else {
		for k, i in kids {
			if k.id == after {
				lo = k.position
				if i + 1 < len(kids) {
					hi = kids[i + 1].position
				}
			}
		}
	}
	c := tick(b)
	append(
		&b.file.items,
		Bookmark {
			id = new_uuid(),
			kind = strings.clone(kind),
			parent = strings.clone(par),
			position = key_between(lo, hi),
			title = strings.clone(title),
			url = strings.clone(url),
			created = now_ms(),
			content_clock = c,
			place_clock = strings.clone(c),
			life_clock = strings.clone(c),
		},
	)
	b.dirty = true
	return &b.file.items[len(b.file.items) - 1]
}

bookmark_edit :: proc(b: ^Bookmarks, id: string, title, url: string) -> bool {
	r := find(b, id)
	if r == nil || is_root(id) && url != "" {
		return false
	}
	r.title = strings.clone(title)
	r.url = strings.clone(url)
	r.content_clock = tick(b)
	b.dirty = true
	return true
}

// bookmark_move places `id` in `parent` after `after` ("" = first).
bookmark_move :: proc(b: ^Bookmarks, id, parent: string, after: string) -> bool {
	r := find(b, id)
	p := find(b, parent)
	if r == nil || p == nil || p.kind != "folder" || is_root(id) {
		return false
	}
	// refuse to move a folder into itself or a descendant
	for at := parent; at != ""; {
		if at == id {
			return false
		}
		q := find(b, at)
		if q == nil {
			break
		}
		at = q.parent
	}
	kids := children(b, parent, context.temp_allocator)
	lo, hi := "", ""
	if after == "" {
		if len(kids) > 0 && kids[0].id != id {
			hi = kids[0].position
		} else if len(kids) > 1 {
			hi = kids[1].position
		}
	} else {
		for k, i in kids {
			if k.id == after {
				lo = k.position
				for j := i + 1; j < len(kids); j += 1 {
					if kids[j].id != id {
						hi = kids[j].position
						break
					}
				}
			}
		}
	}
	if lo != "" && hi != "" && lo >= hi {
		hi = ""
	}
	r.parent = strings.clone(parent)
	r.position = key_between(lo, hi)
	r.place_clock = tick(b)
	b.dirty = true
	return true
}

bookmark_delete :: proc(b: ^Bookmarks, id: string) -> bool {
	r := find(b, id)
	if r == nil || r.deleted || is_root(id) {
		return false
	}
	r.deleted = true
	r.life_clock = tick(b)
	b.dirty = true
	return true
}

is_root :: proc(id: string) -> bool {
	return id == ROOT_TOOLBAR || id == ROOT_OTHER
}

// ---------------------------------------------------------------------------
// Merging
// ---------------------------------------------------------------------------

// merge_record folds `in_` into `local` group by group. It reports whether
// anything local changed.
merge_record :: proc(local: ^Bookmark, in_: Bookmark) -> bool {
	changed := false
	if in_.content_clock > local.content_clock {
		local.title = strings.clone(in_.title)
		local.url = strings.clone(in_.url)
		local.content_clock = strings.clone(in_.content_clock)
		if in_.kind != "" {
			local.kind = strings.clone(in_.kind)
		}
		changed = true
	}
	if in_.place_clock > local.place_clock {
		local.parent = strings.clone(in_.parent)
		local.position = strings.clone(in_.position)
		local.place_clock = strings.clone(in_.place_clock)
		changed = true
	}
	if in_.life_clock > local.life_clock {
		local.deleted = in_.deleted
		local.life_clock = strings.clone(in_.life_clock)
		changed = true
	}
	if local.created == 0 || (in_.created != 0 && in_.created < local.created) {
		local.created = in_.created
	}
	return changed
}

// merge folds a batch of remote records in. It is commutative, associative
// and idempotent -- the properties that let two devices sync in any order,
// any number of times, and agree. The self-test checks all three.
merge :: proc(b: ^Bookmarks, incoming: []Bookmark) -> (changed: int) {
	for in_ in incoming {
		if in_.id == "" {
			continue
		}
		observe(b, clock_max(clock_max(in_.content_clock, in_.place_clock), in_.life_clock))
		if r := find(b, in_.id); r != nil {
			if merge_record(r, in_) {
				changed += 1
			}
		} else {
			copy_ := Bookmark {
				id            = strings.clone(in_.id),
				kind          = strings.clone(in_.kind == "" ? "bookmark" : in_.kind),
				parent        = strings.clone(in_.parent),
				position      = strings.clone(in_.position),
				title         = strings.clone(in_.title),
				url           = strings.clone(in_.url),
				created       = in_.created,
				deleted       = in_.deleted,
				content_clock = strings.clone(in_.content_clock),
				place_clock   = strings.clone(in_.place_clock),
				life_clock    = strings.clone(in_.life_clock),
			}
			append(&b.file.items, copy_)
			changed += 1
		}
	}
	if changed > 0 {
		b.dirty = true
	}
	return
}

// pending is what a sync would push: every record changed after the last
// successful push.
pending :: proc(b: ^Bookmarks, allocator := context.allocator) -> []Bookmark {
	out := make([dynamic]Bookmark, allocator)
	for &r in b.file.items {
		if record_clock(&r) > b.file.pushed_through && !strings.has_suffix(r.life_clock, "-root") {
			append(&out, r)
		}
	}
	return out[:]
}

// mark_pushed records that everything up to `clock` reached the account.
mark_pushed :: proc(b: ^Bookmarks, clock: string) {
	if clock > b.file.pushed_through {
		b.file.pushed_through = strings.clone(clock)
		b.dirty = true
	}
}

// ---------------------------------------------------------------------------
// Reading the tree
// ---------------------------------------------------------------------------

// effective_parent applies the two read-time rules described at the top:
// orphans and cycles are shown under Other Bookmarks, unless they were deleted
// along with their folder. ok is false when the record should not be shown.
effective_parent :: proc(b: ^Bookmarks, r: ^Bookmark) -> (parent: string, ok: bool) {
	if r.deleted {
		return "", false
	}
	if is_root(r.id) {
		return "", true
	}
	p := find(b, r.parent)
	if p == nil {
		return ROOT_OTHER, true
	}
	if p.deleted {
		if r.place_clock > p.life_clock {
			return ROOT_OTHER, true
		}
		return "", false
	}
	// walk up looking for a cycle or a deleted ancestor
	seen := 0
	at := p
	for at != nil && !is_root(at.id) {
		seen += 1
		if seen > 64 || at.id == r.id {
			return ROOT_OTHER, true // a cycle: break it here
		}
		if at.deleted {
			return "", false
		}
		at = find(b, at.parent)
	}
	return r.parent, true
}

// children lists the visible records under `parent`, in order.
children :: proc(b: ^Bookmarks, parent: string, allocator := context.allocator) -> []Bookmark {
	out := make([dynamic]Bookmark, allocator)
	for &r in b.file.items {
		if is_root(r.id) {
			continue
		}
		if par, ok := effective_parent(b, &r); ok && par == parent {
			append(&out, r)
		}
	}
	slice.sort_by(out[:], proc(x, y: Bookmark) -> bool {
		if x.position != y.position {
			return x.position < y.position
		}
		return x.id < y.id
	})
	return out[:]
}

// all_visible is every visible bookmark (not folders), depth-first.
all_visible :: proc(b: ^Bookmarks, allocator := context.allocator) -> []Bookmark {
	out := make([dynamic]Bookmark, allocator)
	walk :: proc(b: ^Bookmarks, parent: string, out: ^[dynamic]Bookmark) {
		for k in children(b, parent, context.temp_allocator) {
			if k.kind == "folder" {
				walk(b, k.id, out)
			} else if k.kind == "bookmark" {
				append(out, k)
			}
		}
	}
	walk(b, ROOT_TOOLBAR, &out)
	walk(b, ROOT_OTHER, &out)
	return out[:]
}

// folders lists every visible folder with its path, for pickers.
Folder_Ref :: struct {
	id:    string,
	path:  string,
	depth: int,
}

folders :: proc(b: ^Bookmarks, allocator := context.allocator) -> []Folder_Ref {
	out := make([dynamic]Folder_Ref, allocator)
	walk :: proc(b: ^Bookmarks, id, path: string, depth: int, out: ^[dynamic]Folder_Ref, allocator: runtime.Allocator) {
		append(out, Folder_Ref{id = id, path = path, depth = depth})
		for k in children(b, id, context.temp_allocator) {
			if k.kind == "folder" {
				walk(b, k.id, fmt.aprintf("%s / %s", path, k.title, allocator = allocator), depth + 1, out, allocator)
			}
		}
	}
	walk(b, ROOT_TOOLBAR, "Bookmarks bar", 0, &out, allocator)
	walk(b, ROOT_OTHER, "Other bookmarks", 0, &out, allocator)
	return out[:]
}

// bookmarked returns the visible bookmark of `url`, if there is one.
bookmarked :: proc(b: ^Bookmarks, url: string) -> ^Bookmark {
	if url == "" {
		return nil
	}
	for &r in b.file.items {
		if r.kind == "bookmark" && url_same(r.url, url) {
			if _, ok := effective_parent(b, &r); ok {
				return &r
			}
		}
	}
	return nil
}

// url_same compares addresses the way a person would: a bare host and the
// same host with its root slash are one page.
url_same :: proc(a, b: string) -> bool {
	if a == b {
		return true
	}
	ta := strings.trim_suffix(a, "/")
	tb := strings.trim_suffix(b, "/")
	return ta == tb && strings.count(ta, "/") == 2
}

// find_folder resolves a folder by id, or by a case-insensitive title, for
// the command line.
find_folder :: proc(b: ^Bookmarks, name: string) -> string {
	switch strings.to_lower(name, context.temp_allocator) {
	case "", "other", "other bookmarks":
		return ROOT_OTHER
	case "toolbar", "bar", "bookmarks bar":
		return ROOT_TOOLBAR
	}
	if r := find(b, name); r != nil && r.kind == "folder" {
		return r.id
	}
	for &r in b.file.items {
		if r.kind == "folder" && strings.equal_fold(r.title, name) {
			if _, ok := effective_parent(b, &r); ok {
				return r.id
			}
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Netscape bookmark files: what every browser imports and exports
// ---------------------------------------------------------------------------

export_html :: proc(b: ^Bookmarks, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n")
	strings.write_string(&sb, "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n")
	strings.write_string(&sb, "<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n<DL><p>\n")
	write :: proc(sb: ^strings.Builder, b: ^Bookmarks, parent: string, depth: int) {
		for k in children(b, parent, context.temp_allocator) {
			for _ in 0 ..< depth {
				strings.write_string(sb, "    ")
			}
			switch k.kind {
			case "folder":
				fmt.sbprintf(sb, "<DT><H3 ADD_DATE=\"%d\">%s</H3>\n", k.created / 1000, html_escape(k.title))
				for _ in 0 ..< depth {
					strings.write_string(sb, "    ")
				}
				strings.write_string(sb, "<DL><p>\n")
				write(sb, b, k.id, depth + 1)
				for _ in 0 ..< depth {
					strings.write_string(sb, "    ")
				}
				strings.write_string(sb, "</DL><p>\n")
			case "separator":
				strings.write_string(sb, "<HR>\n")
			case:
				fmt.sbprintf(sb, "<DT><A HREF=\"%s\" ADD_DATE=\"%d\">%s</A>\n", html_escape(k.url), k.created / 1000, html_escape(k.title))
			}
		}
	}
	strings.write_string(&sb, "    <DT><H3 PERSONAL_TOOLBAR_FOLDER=\"true\">Bookmarks bar</H3>\n    <DL><p>\n")
	write(&sb, b, ROOT_TOOLBAR, 2)
	strings.write_string(&sb, "    </DL><p>\n")
	write(&sb, b, ROOT_OTHER, 1)
	strings.write_string(&sb, "</DL><p>\n")
	return strings.to_string(sb)
}

html_escape :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for c in s {
		switch c {
		case '&':
			strings.write_string(&sb, "&amp;")
		case '<':
			strings.write_string(&sb, "&lt;")
		case '>':
			strings.write_string(&sb, "&gt;")
		case '"':
			strings.write_string(&sb, "&quot;")
		case:
			strings.write_rune(&sb, c)
		}
	}
	return strings.to_string(sb)
}

html_unescape :: proc(s: string) -> string {
	if !strings.contains(s, "&") {
		return s
	}
	r, _ := strings.replace_all(s, "&lt;", "<", context.temp_allocator)
	r, _ = strings.replace_all(r, "&gt;", ">", context.temp_allocator)
	r, _ = strings.replace_all(r, "&quot;", "\"", context.temp_allocator)
	r, _ = strings.replace_all(r, "&#39;", "'", context.temp_allocator)
	r, _ = strings.replace_all(r, "&amp;", "&", context.temp_allocator)
	return r
}

// import_html reads a Netscape bookmark file (Firefox, Chromium, Safari and
// Edge all export one) into a new folder under Other Bookmarks, or into the
// bar for the folder marked PERSONAL_TOOLBAR_FOLDER. Returns how many
// bookmarks it added.
import_html :: proc(b: ^Bookmarks, text: string, into := ROOT_OTHER) -> int {
	stack := make([dynamic]string, context.temp_allocator)
	append(&stack, into)
	pending_folder := ""
	added := 0
	rest := text
	for len(rest) > 0 {
		i := strings.index_byte(rest, '<')
		if i < 0 {
			break
		}
		rest = rest[i:]
		upper := strings.to_upper(rest[:min(len(rest), 16)], context.temp_allocator)
		switch {
		case strings.has_prefix(upper, "<DL"):
			if pending_folder != "" {
				append(&stack, pending_folder)
				pending_folder = ""
			} else if len(stack) > 0 {
				append(&stack, stack[len(stack) - 1])
			}
			rest = rest[3:]
		case strings.has_prefix(upper, "</DL"):
			if len(stack) > 1 {
				pop(&stack)
			}
			rest = rest[4:]
		case strings.has_prefix(upper, "<H3"):
			close := strings.index_byte(rest, '>')
			end := strings.index(strings.to_upper(rest, context.temp_allocator), "</H3>")
			if close < 0 || end < 0 || end < close {
				rest = rest[3:]
				continue
			}
			attrs := rest[:close]
			title := html_unescape(strings.trim_space(rest[close + 1:end]))
			parent := stack[len(stack) - 1]
			if strings.contains(strings.to_upper(attrs, context.temp_allocator), "PERSONAL_TOOLBAR_FOLDER") {
				pending_folder = ROOT_TOOLBAR
			} else {
				f := bookmark_add(b, parent, title, "", "folder")
				pending_folder = f.id
			}
			rest = rest[end + 5:]
		case strings.has_prefix(upper, "<A "):
			close := strings.index_byte(rest, '>')
			end := strings.index(strings.to_upper(rest, context.temp_allocator), "</A>")
			if close < 0 || end < 0 || end < close {
				rest = rest[2:]
				continue
			}
			attrs := rest[:close]
			title := html_unescape(strings.trim_space(rest[close + 1:end]))
			href := ""
			up := strings.to_upper(attrs, context.temp_allocator)
			if h := strings.index(up, "HREF=\""); h >= 0 {
				v := attrs[h + 6:]
				if q := strings.index_byte(v, '"'); q >= 0 {
					href = html_unescape(v[:q])
				}
			}
			if href != "" && !strings.has_prefix(strings.to_lower(href, context.temp_allocator), "javascript:") {
				bookmark_add(b, stack[len(stack) - 1], title == "" ? href : title, href)
				added += 1
			}
			rest = rest[end + 4:]
		case:
			rest = rest[1:]
		}
	}
	return added
}
