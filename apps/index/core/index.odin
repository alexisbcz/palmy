// One identity's index: a directory of segments and the manifest that says
// which of them are live.
//
//	<root>/<handle>/              0700, one per identity, nothing shared
//	    manifest                  which segments and tombstone files are live
//	    s<N>.seg                  segments (segment.odin)
//	    s<N>.g<G>.del             dead doc numbers of segment N as of generation G
//	    identity                  the identity this directory belongs to
//	    status                    what the daemon last did, for `index status`
//	    lock                      held by the one writer (flock)
//	    rebuild                   present = a rebuild was asked for
//
// The root is $PALM_INDEX_DIR, else $XDG_DATA_HOME/palm/index, else
// ~/.local/share/palm/index. Deleting an identity's directory removes it
// from this device's search, which is the product rule (product.md §6).
//
// Readers never take a lock. A writer writes new segment and tombstone
// files, then renames a new manifest over the old one; a reader that sees
// the old manifest keeps its mapped files, which unlinking does not disturb.
package indexcore

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

index_root :: proc(allocator := context.allocator) -> string {
	if d := os.get_env("PALM_INDEX_DIR", context.temp_allocator); d != "" {
		return strings.clone(d, allocator)
	}
	if d := os.get_env("XDG_DATA_HOME", context.temp_allocator); d != "" {
		return fmt.aprintf("%s/palm/index", d, allocator = allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	return fmt.aprintf("%s/.local/share/palm/index", home, allocator = allocator)
}

// handle_ok is the same rule cloudkit applies: a handle names a directory,
// so it must not be able to climb out of the root.
handle_ok :: proc(h: string) -> bool {
	if len(h) == 0 || len(h) > 64 || h[0] == '.' {
		return false
	}
	for c in transmute([]u8)h {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '_', '-':
		case:
			return false
		}
	}
	return true
}

identity_dir :: proc(root, handle: string, allocator := context.allocator) -> string {
	return fmt.aprintf("%s/%s", root, handle, allocator = allocator)
}

Index :: struct {
	handle: string,
	dir:    string,
	gen:    int,
	next:   int, // next segment number
	segs:   [dynamic]^Segment,
	dels:   [dynamic]string, // tombstone file per segment, "" for none
	mtime:  i64, // the manifest's, when this was loaded
	total:  u64, // sum of token counts over live segments
	ndocs:  int, // live documents
}

@(private)
manifest_mtime :: proc(dir: string) -> i64 {
	st: linux.Stat
	p := strings.clone_to_cstring(fmt.tprintf("%s/manifest", dir), context.temp_allocator)
	if linux.stat(p, &st) != .NONE {
		return 0
	}
	return i64(st.mtime.time_sec) * 1_000_000_000 + i64(st.mtime.time_nsec)
}

// index_open loads an identity's index for reading. A directory with no
// manifest is an empty index, not an error: nothing has been indexed yet.
index_open :: proc(root, handle: string) -> (ix: ^Index, ok: bool) {
	if !handle_ok(handle) {
		return nil, false
	}
	ix = new(Index)
	ix.handle = strings.clone(handle)
	ix.dir = identity_dir(root, handle)
	if !index_load(ix) {
		index_close(ix)
		return nil, false
	}
	return ix, true
}

index_close :: proc(ix: ^Index) {
	if ix == nil {
		return
	}
	index_unload(ix)
	delete(ix.handle)
	delete(ix.dir)
	delete(ix.segs)
	delete(ix.dels)
	free(ix)
}

@(private)
index_unload :: proc(ix: ^Index) {
	for s in ix.segs {
		segment_close(s)
	}
	for d in ix.dels {
		delete(d)
	}
	clear(&ix.segs)
	clear(&ix.dels)
	ix.total = 0
	ix.ndocs = 0
}

// index_load (re)reads the manifest and maps what it names. It retries when
// a writer swaps the manifest between our reading it and opening a file.
index_load :: proc(ix: ^Index) -> bool {
	for attempt in 0 ..< 4 {
		index_unload(ix)
		ix.mtime = manifest_mtime(ix.dir)
		path := fmt.tprintf("%s/manifest", ix.dir)
		note_open(path)
		data, err := os.read_entire_file_from_path(path, context.temp_allocator)
		if err != nil {
			ix.gen = 0
			ix.next = 1
			return true // no manifest yet: empty
		}
		good := true
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			f := strings.fields(line, context.temp_allocator)
			if len(f) == 0 {
				continue
			}
			switch f[0] {
			case "gen":
				if len(f) > 1 {
					ix.gen, _ = strconv.parse_int(f[1])
				}
			case "next":
				if len(f) > 1 {
					ix.next, _ = strconv.parse_int(f[1])
				}
			case "seg":
				if len(f) < 2 {
					continue
				}
				s, sok := segment_open(fmt.tprintf("%s/%s.seg", ix.dir, f[1]), f[1])
				if !sok {
					good = false
					break
				}
				del := ""
				if len(f) > 2 && f[2] != "-" {
					del = strings.clone(f[2])
					dpath := fmt.tprintf("%s/%s", ix.dir, del)
					note_open(dpath)
					dd, derr := os.read_entire_file_from_path(dpath, context.temp_allocator)
					if derr != nil {
						segment_close(s)
						delete(del)
						good = false
						break
					}
					for n in slice.reinterpret([]u32, dd[:len(dd) / 4 * 4]) {
						if int(n) < len(s.dead) && !s.dead[n] {
							s.dead[n] = true
							s.ndead += 1
						}
					}
				}
				append(&ix.segs, s)
				append(&ix.dels, del)
			}
			if !good {
				break
			}
		}
		if good {
			for s in ix.segs {
				ix.total += s.hdr.total_len
				ix.ndocs += segment_live(s)
			}
			if ix.next == 0 {
				ix.next = 1
			}
			return true
		}
		_ = attempt
	}
	return false
}

// index_refresh reloads when the manifest has changed since we read it.
// One stat; this is what lets Home see a mail seconds after it arrives.
index_refresh :: proc(ix: ^Index) -> (changed: bool) {
	if manifest_mtime(ix.dir) == ix.mtime {
		return false
	}
	index_load(ix)
	return true
}

// ---------------------------------------------------------------------------
// Writing: only the daemon (or `index rebuild`) holds a Writer.
// ---------------------------------------------------------------------------

Loc :: struct {
	seg: int, // index into ix.segs
	doc: u32,
	sig: u64,
}

Writer :: struct {
	ix:      ^Index,
	lock_fd: linux.Fd,
	keys:    map[u64]Loc, // key hash -> where the live copy is
	pending: Builder, // documents added since the last flush
	pkeys:   map[u64]int, // key hash -> pending doc number
	gone:    map[u64]bool, // keys removed since the last flush
	ops:     int,
}

// writer_open takes the identity's lock, creating its directory 0700. It
// fails when another writer holds it.
writer_open :: proc(root, handle: string) -> (w: ^Writer, err: string) {
	if !handle_ok(handle) {
		return nil, "not an identity handle"
	}
	dir := identity_dir(root, handle, context.temp_allocator)
	os.make_directory_all(dir, os.perm_number(0o700))
	linux.chmod(strings.clone_to_cstring(dir, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	lp := strings.clone_to_cstring(fmt.tprintf("%s/lock", dir), context.temp_allocator)
	fd, e := linux.open(lp, {.CREAT, .RDWR, .CLOEXEC}, {.IRUSR, .IWUSR})
	if e != .NONE {
		return nil, fmt.tprintf("cannot open %s/lock", dir)
	}
	if linux.flock(fd, {.EX, .NB}) != .NONE {
		linux.close(fd)
		return nil, "another indexer holds this identity's lock"
	}
	ix, ok := index_open(root, handle)
	if !ok {
		linux.close(fd)
		return nil, "the index could not be read"
	}
	w = new(Writer)
	w.ix = ix
	w.lock_fd = fd
	builder_init(&w.pending)
	writer_rekey(w)
	return w, ""
}

writer_close :: proc(w: ^Writer) {
	if w == nil {
		return
	}
	builder_destroy(&w.pending)
	delete(w.keys)
	delete(w.pkeys)
	delete(w.gone)
	index_close(w.ix)
	linux.close(w.lock_fd)
	free(w)
}

@(private)
writer_rekey :: proc(w: ^Writer) {
	clear(&w.keys)
	for s, si in w.ix.segs {
		for d, di in s.docs {
			if !s.dead[di] {
				w.keys[d.key_hash] = Loc{si, u32(di), d.sig}
			}
		}
	}
}

// writer_sig is the signature the index holds for a key, so a source can
// skip what has not changed. found = false when the key is not indexed.
writer_sig :: proc(w: ^Writer, key: string) -> (sig: u64, found: bool) {
	h := fnv64(key)
	if h in w.gone {
		return 0, false
	}
	if n, ok := w.pkeys[h]; ok {
		return w.pending.docs[n].sig, true
	}
	if l, ok := w.keys[h]; ok {
		return l.sig, true
	}
	return 0, false
}

// writer_put adds or replaces a document. It becomes visible at the next
// flush.
writer_put :: proc(w: ^Writer, d: Doc) {
	h := fnv64(d.key)
	if n, ok := w.pkeys[h]; ok {
		// Replaced twice before a flush: the older pending copy is dropped
		// by making the newer one win at flush (later doc numbers win).
		_ = n
	}
	delete_key(&w.gone, h)
	w.pkeys[h] = builder_ndocs(&w.pending)
	builder_add(&w.pending, d)
	w.ops += 1
	if builder_ndocs(&w.pending) >= MAX_SEG_DOCS {
		writer_flush(w) // bounds memory during a first build
	}
}

writer_remove :: proc(w: ^Writer, key: string) {
	h := fnv64(key)
	if _, ok := w.pkeys[h]; ok {
		delete_key(&w.pkeys, h)
	}
	w.gone[h] = true
	w.ops += 1
}

// writer_keys lists the keys the index holds that start with `prefix`, so a
// source can remove what disappeared from it. Strings are temp-allocated.
writer_keys :: proc(w: ^Writer, prefix: string, allocator := context.temp_allocator) -> [dynamic]string {
	out := make([dynamic]string, allocator)
	for s in w.ix.segs {
		for _, di in s.docs {
			if s.dead[di] {
				continue
			}
			k := doc_stored(s, di).key
			if strings.has_prefix(k, prefix) {
				append(&out, k)
			}
		}
	}
	for d, i in w.pending.docs {
		if !pending_wins(w, d.key_hash, i) {
			continue
		}
		pos := int(d.store_off)
		n := int(get_uvarint(w.pending.store[:], &pos))
		k := string(w.pending.store[pos:][:n])
		if strings.has_prefix(k, prefix) {
			append(&out, strings.clone(k, allocator))
		}
	}
	return out
}

// pending_wins says pending doc `i` is the live copy of its key: not put
// again later, and not removed since.
@(private)
pending_wins :: proc(w: ^Writer, h: u64, i: int) -> bool {
	n, ok := w.pkeys[h]
	return ok && n == i
}

writer_dirty :: proc(w: ^Writer) -> bool {
	return w.ops > 0
}

// writer_flush makes everything put or removed since the last flush
// visible: one new segment, new tombstones, one manifest rename.
writer_flush :: proc(w: ^Writer) -> bool {
	if w.ops == 0 {
		return true
	}
	ix := w.ix
	new_dead := make(map[int][dynamic]u32, allocator = context.temp_allocator)
	kill :: proc(m: ^map[int][dynamic]u32, l: Loc) {
		if l.seg not_in m {
			m[l.seg] = make([dynamic]u32, context.temp_allocator)
		}
		append(&m[l.seg], l.doc)
	}
	// Every replaced or removed key kills its live copy.
	for h in w.gone {
		if l, ok := w.keys[h]; ok {
			kill(&new_dead, l)
		}
	}
	for h in w.pkeys {
		if l, ok := w.keys[h]; ok {
			kill(&new_dead, l)
		}
	}

	gen := ix.gen + 1
	seg_name := ""
	if len(w.pending.docs) > 0 {
		// Pending docs superseded before this flush are compacted out by
		// rebuilding only the winners.
		superseded := false
		for d, i in w.pending.docs {
			if !pending_wins(w, d.key_hash, i) {
				superseded = true
				break
			}
		}
		b := &w.pending
		fresh: Builder
		if superseded {
			builder_init(&fresh)
			for d, i in w.pending.docs {
				if !pending_wins(w, d.key_hash, i) {
					continue
				}
				builder_add(&fresh, pending_doc(&w.pending, i))
			}
			b = &fresh
		}
		if len(b.docs) > 0 {
			seg_name = fmt.tprintf("s%08d", ix.next)
			if !builder_write(b, fmt.tprintf("%s/%s.seg", ix.dir, seg_name)) {
				if superseded {
					builder_destroy(&fresh)
				}
				return false
			}
		}
		if superseded {
			builder_destroy(&fresh)
		}
	}
	if !write_manifest(w, gen, seg_name, new_dead, nil) {
		return false
	}
	// Where each winner landed in the new segment, computed before the
	// pending state is dropped: the key map is updated in place rather than
	// rebuilt, which is what keeps a one-mail flush cheap on a big index.
	landed := make([dynamic]struct {
			h:   u64,
			sig: u64,
		}, context.temp_allocator)
	for d, i in w.pending.docs {
		if pending_wins(w, d.key_hash, i) {
			append(&landed, struct {
				h:   u64,
				sig: u64,
			}{d.key_hash, d.sig})
		}
	}
	gone := make([dynamic]u64, context.temp_allocator)
	for h in w.gone {
		append(&gone, h)
	}
	builder_destroy(&w.pending)
	builder_init(&w.pending)
	clear(&w.pkeys)
	clear(&w.gone)
	w.ops = 0
	nseg := len(ix.segs)
	index_load(ix)
	if len(ix.segs) == nseg + (seg_name != "" ? 1 : 0) {
		for h in gone {
			delete_key(&w.keys, h)
		}
		for l, n in landed {
			w.keys[l.h] = Loc{len(ix.segs) - 1, u32(n), l.sig}
		}
	} else {
		writer_rekey(w)
	}
	gc(ix)
	return true
}

@(private)
pending_doc :: proc(b: ^Builder, i: int) -> Doc {
	r := b.docs[i]
	data := b.store[r.store_off:][:r.store_len]
	pos := 0
	field :: proc(data: []u8, pos: ^int) -> string {
		n := int(get_uvarint(data, pos))
		v := string(data[pos^:][:n])
		pos^ += n
		return v
	}
	d: Doc
	d.key = field(data, &pos)
	d.title = field(data, &pos)
	d.who = field(data, &pos)
	d.detail = field(data, &pos)
	d.uri = field(data, &pos)
	d.app = field(data, &pos)
	d.body = field(data, &pos)
	d.kind = r.kind
	d.flags = r.flags
	d.time = r.time
	d.dur = r.dur
	d.sig = r.sig
	return d
}

// write_manifest writes tombstones and the manifest for generation `gen`:
// the current segments minus `drop`, plus `added` if non-empty.
@(private)
write_manifest :: proc(w: ^Writer, gen: int, added: string, new_dead: map[int][dynamic]u32, drop: []int) -> bool {
	ix := w.ix
	sb := strings.builder_make(context.temp_allocator)
	next := ix.next + (added != "" ? 1 : 0)
	fmt.sbprintf(&sb, "palm-index 1\ngen %d\nnext %d\n", gen, next)
	for s, si in ix.segs {
		if slice.contains(drop, si) {
			continue
		}
		del := ix.dels[si]
		if extra, ok := new_dead[si]; ok && len(extra) > 0 {
			ids := make([dynamic]u32, context.temp_allocator)
			for d, di in s.dead {
				if d {
					append(&ids, u32(di))
				}
			}
			append(&ids, ..extra[:])
			del = fmt.tprintf("%s.g%d.del", s.name, gen)
			if os.write_entire_file(fmt.tprintf("%s/%s", ix.dir, del), slice.to_bytes(ids[:]), os.perm_number(0o600)) != nil {
				return false
			}
		}
		fmt.sbprintf(&sb, "seg %s %s\n", s.name, del == "" ? "-" : del)
	}
	if added != "" {
		fmt.sbprintf(&sb, "seg %s -\n", added)
	}
	tmp := fmt.tprintf("%s/manifest.tmp", ix.dir)
	if os.write_entire_file(tmp, transmute([]u8)strings.to_string(sb), os.perm_number(0o600)) != nil {
		return false
	}
	return os.rename(tmp, fmt.tprintf("%s/manifest", ix.dir)) == nil
}

// gc removes segment and tombstone files the manifest no longer names.
@(private)
gc :: proc(ix: ^Index) {
	live := make(map[string]bool, allocator = context.temp_allocator)
	for s, i in ix.segs {
		live[fmt.tprintf("%s.seg", s.name)] = true
		if ix.dels[i] != "" {
			live[ix.dels[i]] = true
		}
	}
	entries, err := os.read_all_directory_by_path(ix.dir, context.temp_allocator)
	if err != nil {
		return
	}
	for e in entries {
		n := e.name
		if !(strings.has_suffix(n, ".seg") || strings.has_suffix(n, ".del") || strings.has_suffix(n, ".tmp")) {
			continue
		}
		if n == "manifest.tmp" || n in live {
			continue
		}
		os.remove(fmt.tprintf("%s/%s", ix.dir, n))
	}
}

// MAX_SEG_DOCS bounds a segment, so building or merging one never holds
// more than this many documents' postings in memory (about 80 MB for mail).
// A big identity ends up as a few segments of this size, which a query
// reads one after the other at no measurable cost.
MAX_SEG_DOCS :: 32_000

// writer_merge does at most one merge and says whether it did, so the
// daemon can spread merges over idle time. In order:
//
//	a segment more than a quarter dead is rewritten without its dead
//	a size class (powers of 8 of live documents) with more than `fanout`
//	  members has its smallest merged, up to MAX_SEG_DOCS
//	force: any two neighbours that fit in MAX_SEG_DOCS together
writer_merge :: proc(w: ^Writer, fanout := 6, force := false) -> bool {
	ix := w.ix
	if w.ops > 0 && !writer_flush(w) {
		return false
	}
	pick := make([dynamic]int, context.temp_allocator)
	for s, i in ix.segs {
		if s.ndead > 0 && (s.ndead * 4 > len(s.docs) || force) {
			append(&pick, i)
			return merge_segments(w, pick[:])
		}
	}
	class :: proc(n: int) -> int {
		c := 0
		for x := max(n, 1); x >= 8; x /= 8 {
			c += 1
		}
		return min(c, 15)
	}
	counts: [16]int
	for s in ix.segs {
		counts[class(segment_live(s))] += 1
	}
	target := -1
	for c in 0 ..< 16 {
		if counts[c] > fanout || (force && counts[c] > 1) {
			target = c
			break
		}
	}
	if target < 0 && force {
		// Different classes, but small enough to share a segment.
		order := make([dynamic]int, context.temp_allocator)
		for _, i in ix.segs {
			append(&order, i)
		}
		segs := ix.segs[:]
		context.user_ptr = &segs
		slice.sort_by(order[:], proc(a, b: int) -> bool {
			s := (^[]^Segment)(context.user_ptr)^
			return segment_live(s[a]) < segment_live(s[b])
		})
		if len(order) >= 2 && segment_live(ix.segs[order[0]]) + segment_live(ix.segs[order[1]]) <= MAX_SEG_DOCS {
			append(&pick, order[0], order[1])
			return merge_segments(w, pick[:])
		}
		return false
	}
	if target < 0 {
		return false
	}
	sum := 0
	for s, i in ix.segs {
		if class(segment_live(s)) == target && sum + segment_live(s) <= MAX_SEG_DOCS {
			append(&pick, i)
			sum += segment_live(s)
		}
	}
	if len(pick) < 2 {
		return false
	}
	return merge_segments(w, pick[:])
}

// merge_segments replaces the picked segments with one holding their live
// documents, rebuilt from stored text.
@(private)
merge_segments :: proc(w: ^Writer, pick: []int) -> bool {
	ix := w.ix
	b: Builder
	builder_init(&b)
	defer builder_destroy(&b)
	for si in pick {
		s := ix.segs[si]
		for _, di in s.docs {
			if !s.dead[di] {
				builder_add(&b, doc_from_stored(s, di))
			}
		}
	}
	name := ""
	if len(b.docs) > 0 {
		name = fmt.tprintf("s%08d", ix.next)
		if !builder_write(&b, fmt.tprintf("%s/%s.seg", ix.dir, name)) {
			return false
		}
	}
	if !write_manifest(w, ix.gen + 1, name, {}, pick) {
		return false
	}
	index_load(ix)
	writer_rekey(w)
	gc(ix)
	return true
}

// writer_compact merges until nothing is left to merge.
writer_compact :: proc(w: ^Writer) {
	for writer_merge(w, force = true) {
	}
}

// writer_clear empties the index (for a rebuild): every segment dropped.
writer_clear :: proc(w: ^Writer) -> bool {
	builder_destroy(&w.pending)
	builder_init(&w.pending)
	clear(&w.pkeys)
	clear(&w.gone)
	w.ops = 0
	all := make([dynamic]int, context.temp_allocator)
	for _, i in w.ix.segs {
		append(&all, i)
	}
	if !write_manifest(w, w.ix.gen + 1, "", {}, all[:]) {
		return false
	}
	index_load(w.ix)
	writer_rekey(w)
	gc(w.ix)
	return true
}

// index_bytes is the size on disk of the live files.
index_bytes :: proc(ix: ^Index) -> i64 {
	n: i64
	for s in ix.segs {
		n += i64(len(s.data))
	}
	return n
}
