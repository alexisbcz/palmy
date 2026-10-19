// The sync engine: one pass of reconciling ~/Drive/<handle>/ with the
// identity's drive. See cloud/docs/drive.md, "Sync semantics", for the rules
// in prose; this file is those rules and nothing cleverer.
//
// The shape is a three-way merge, state-based rather than operation-based.
// For every path there are three versions:
//
//     base    what this device last agreed with the server on (persisted)
//     local   what is on disk now
//     remote  what the server says now (the feed, applied to a persisted mirror)
//
// A side "changed" when it differs from base. One side changed: apply it to
// the other. Both changed to the same thing: agree. Both changed differently:
// keep both. Nothing is ever decided by timestamps.
//
// Being state-based is what makes the offline queue and resumption fall out
// rather than be built: there is no list of operations to lose. What is
// pending is exactly "local differs from base", recomputed on every pass, so
// a laptop that was edited for a week offline, rebooted twice, and then
// reconnected does the right thing on its first pass. Uploads resume at the
// chunk because chunks are content-addressed (see chunk.odin).
package drivecore

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

Remote :: struct {
	id, parent, name, kind, hash: string,
	seq, size:                    i64,
	trashed:                      bool,
}

Base :: struct {
	id, kind, hash: string,
	size, mtime:    i64,
}

State :: struct {
	cursor: i64,
	remote: map[string]Remote, // by item id: a mirror of the feed
	base:   map[string]Base, // by relative path
}

Local :: struct {
	kind:        string,
	size, mtime: i64,
	hash:        string,
}

Pass :: struct {
	offline:        bool,
	dry_run:        bool,
	uploaded:       int,
	downloaded:     int,
	deleted_local:  int,
	trashed_remote: int,
	moved_local:    int,
	moved_remote:   int,
	folders:        int,
	conflicts:      int,
	agreed:         int,
	sent_chunks:    int,
	skipped_chunks: int,
	sent_bytes:     i64,
	actions:        [dynamic]string, // what was done (or, dry-run/offline, would be)
	errors:         [dynamic]string,
}

pass_changed :: proc(p: ^Pass) -> bool {
	return(
		p.uploaded + p.downloaded + p.deleted_local + p.trashed_remote + p.moved_local + p.moved_remote + p.folders + p.conflicts >
		0 \
	)
}

TEMP_PREFIX :: ".palm-drive-"

// ---------------------------------------------------------------------------
// State on disk
// ---------------------------------------------------------------------------

state_path :: proc(cfg: ^Config, id: ^Identity) -> string {
	return fmt.tprintf("%s/%s.state", cfg.state_dir, id.handle)
}

@(private)
esc :: proc(s: string) -> string {
	if s == "" {
		return "-"
	}
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		switch s[i] {
		case '%', '\t', '\n', '\r':
			fmt.sbprintf(&b, "%%%02X", s[i])
		case '-':
			if len(s) == 1 {
				strings.write_string(&b, "%2D")
			} else {
				strings.write_byte(&b, '-')
			}
		case:
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

@(private)
unesc :: proc(s: string) -> string {
	if s == "-" {
		return ""
	}
	if strings.index_byte(s, '%') < 0 {
		return strings.clone(s)
	}
	b := strings.builder_make()
	i := 0
	for i < len(s) {
		if s[i] == '%' && i + 2 < len(s) {
			v, ok := strconv.parse_int(s[i + 1:i + 3], 16)
			if ok {
				strings.write_byte(&b, u8(v))
				i += 3
				continue
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

load_state :: proc(path: string) -> (st: State) {
	st.remote = make(map[string]Remote)
	st.base = make(map[string]Base)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return
	}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) == 0 {
			continue
		}
		switch f[0] {
		case "cursor":
			if len(f) >= 2 {
				st.cursor, _ = strconv.parse_i64(f[1])
			}
		case "R":
			if len(f) >= 9 {
				r := Remote {
					id      = unesc(f[1]),
					parent  = unesc(f[2]),
					kind    = unesc(f[3]),
					hash    = unesc(f[5]),
					trashed = f[7] == "1",
					name    = unesc(f[8]),
				}
				r.seq, _ = strconv.parse_i64(f[4])
				r.size, _ = strconv.parse_i64(f[6])
				st.remote[r.id] = r
			}
		case "B":
			if len(f) >= 7 {
				b := Base {
					id   = unesc(f[2]),
					kind = unesc(f[3]),
					hash = unesc(f[4]),
				}
				b.size, _ = strconv.parse_i64(f[5])
				b.mtime, _ = strconv.parse_i64(f[6])
				st.base[unesc(f[1])] = b
			}
		}
	}
	return
}

// save_state writes the whole state to a temporary file and renames it over
// the old one, so a crash leaves either the old state or the new, never half.
save_state :: proc(path: string, st: ^State) -> bool {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "# palm-drive sync state; do not edit while the daemon runs\ncursor\t%d\n", st.cursor)
	rkeys := slice.map_keys(st.remote, context.temp_allocator) or_else nil
	slice.sort(rkeys)
	for k in rkeys {
		r := st.remote[k]
		fmt.sbprintf(
			&b,
			"R\t%s\t%s\t%s\t%d\t%s\t%d\t%s\t%s\n",
			esc(r.id),
			esc(r.parent),
			esc(r.kind),
			r.seq,
			esc(r.hash),
			r.size,
			r.trashed ? "1" : "0",
			esc(r.name),
		)
	}
	bkeys := slice.map_keys(st.base, context.temp_allocator) or_else nil
	slice.sort(bkeys)
	for k in bkeys {
		x := st.base[k]
		fmt.sbprintf(&b, "B\t%s\t%s\t%s\t%s\t%d\t%d\n", esc(k), esc(x.id), esc(x.kind), esc(x.hash), x.size, x.mtime)
	}
	dir := path[:max(0, strings.last_index_byte(path, '/'))]
	os.make_directory_all(dir)
	tmp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp, strings.to_string(b)) != nil {
		return false
	}
	return os.rename(tmp, path) == nil
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

parent_of :: proc(p: string) -> string {
	i := strings.last_index_byte(p, '/')
	return i < 0 ? "" : p[:i]
}

base_name :: proc(p: string) -> string {
	i := strings.last_index_byte(p, '/')
	return i < 0 ? p : p[i + 1:]
}

join :: proc(a, b: string) -> string {
	return a == "" ? b : fmt.tprintf("%s/%s", a, b)
}

depth_of :: proc(p: string) -> int {
	return strings.count(p, "/")
}

under :: proc(p, dir: string) -> bool {
	return len(p) > len(dir) && strings.has_prefix(p, dir) && p[len(dir)] == '/'
}

// remote_paths turns the id-keyed mirror into the live tree by path.
// Anything trashed, or under something trashed, or whose parent the mirror
// has not seen, is not live.
remote_paths :: proc(st: ^State) -> (by_path: map[string]Remote, path_of: map[string]string) {
	by_path = make(map[string]Remote, context.temp_allocator)
	path_of = make(map[string]string, context.temp_allocator)
	for id, _ in st.remote {
		p, ok := resolve(st, id, &path_of, 0)
		if ok {
			by_path[p] = st.remote[id]
		}
	}
	return
}

@(private)
resolve :: proc(st: ^State, id: string, memo: ^map[string]string, depth: int) -> (string, bool) {
	if p, ok := memo[id]; ok {
		return p, p != "\x00"
	}
	r, ok := st.remote[id]
	if !ok || r.trashed || depth > 64 {
		return "", false
	}
	p := r.name
	if r.parent != "" {
		pp, pok := resolve(st, r.parent, memo, depth + 1)
		if !pok {
			memo[id] = "\x00"
			return "", false
		}
		p = fmt.tprintf("%s/%s", pp, r.name)
	}
	memo[id] = p
	return p, true
}

// scan walks the local folder. A file's hash is reused from base when its
// size and modification time are what base recorded, so an idle pass reads
// directory entries and nothing else.
scan :: proc(root: string, st: ^State) -> map[string]Local {
	out := make(map[string]Local, context.temp_allocator)
	walk(root, "", st, &out)
	return out
}

@(private)
walk :: proc(root, rel: string, st: ^State, out: ^map[string]Local) {
	dir := rel == "" ? root : fmt.tprintf("%s/%s", root, rel)
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	for fi in entries {
		if strings.has_prefix(fi.name, TEMP_PREFIX) {
			continue
		}
		p := join(rel, strings.clone(fi.name, context.temp_allocator))
		#partial switch fi.type {
		case .Directory:
			out[p] = Local {
				kind = "folder",
			}
			walk(root, p, st, out)
		case .Regular:
			mt := time.to_unix_nanoseconds(fi.modification_time)
			l := Local {
				kind  = "file",
				size  = fi.size,
				mtime = mt,
			}
			if b, ok := st.base[p]; ok && b.kind == "file" && b.size == fi.size && b.mtime == mt {
				l.hash = b.hash
			} else {
				h, hok := hash_file(fmt.tprintf("%s/%s", root, p), context.temp_allocator)
				if !hok {
					continue
				}
				l.hash = h.hash
			}
			out[p] = l
		// Symlinks, devices and sockets are not synced. A symlink in a synced
		// folder would either leak a path from outside it or need a remote
		// representation; neither is worth it yet.
		}
	}
}

stat_mtime :: proc(path: string) -> (size, mtime: i64) {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return -1, -1
	}
	return fi.size, time.to_unix_nanoseconds(fi.modification_time)
}

@(private)
g_offset: Maybe(i64)

// local_offset is this machine's UTC offset in seconds, read once from
// date(1) the way apps/files does: core:time has no local time, and a
// conflict copy stamped in UTC would read as the wrong hour.
local_offset :: proc() -> i64 {
	if v, ok := g_offset.?; ok {
		return v
	}
	off: i64 = 0
	state, out, _, err := os.process_exec({command = {"date", "+%z"}}, context.temp_allocator)
	if err == nil && state.exit_code == 0 && len(out) >= 5 {
		sign: i64 = out[0] == '-' ? -1 : 1
		hh := i64(out[1] - '0') * 10 + i64(out[2] - '0')
		mm := i64(out[3] - '0') * 10 + i64(out[4] - '0')
		off = sign * (hh * 3600 + mm * 60)
	}
	g_offset = off
	return off
}

iso_time :: proc(t: time.Time) -> string {
	s, _ := time.time_to_rfc3339(t, 0, false, context.temp_allocator)
	return s
}

// conflict_name is where the local side of a conflict goes: next to the
// original, saying what it is, which device, and when, in a form that sorts
// beside the original in any file browser.
//
//     report.txt  ->  report (conflicted copy, laptop, 2026-10-19 14.03).txt
conflict_name :: proc(name, device: string, taken: proc(string, rawptr) -> bool, data: rawptr) -> string {
	stem, ext := name, ""
	if dot := strings.last_index_byte(name, '.'); dot > 0 {
		stem, ext = name[:dot], name[dot:]
	}
	now := time.time_add(time.now(), time.Duration(local_offset()) * time.Second)
	y, mo, d := time.date(now)
	hh, mm, _ := time.clock(now)
	stamp := fmt.tprintf("%04d-%02d-%02d %02d.%02d", y, int(mo), d, hh, mm)
	cand := fmt.tprintf("%s (conflicted copy, %s, %s)%s", stem, device, stamp, ext)
	for k := 2; taken(cand, data); k += 1 {
		cand = fmt.tprintf("%s (conflicted copy %d, %s, %s)%s", stem, k, device, stamp, ext)
	}
	return cand
}

// ---------------------------------------------------------------------------
// One pass
// ---------------------------------------------------------------------------

Syncer :: struct {
	c:     Client,
	root:  string,
	st:    State,
	spath: string,
	pass:  ^Pass,
	local: map[string]Local,
	rpath: map[string]Remote,
	idp:   map[string]string,
	stuck: map[string]bool, // moves the server refused this pass; not retried
}

@(private)
act :: proc(s: ^Syncer, format: string, args: ..any) {
	append(&s.pass.actions, fmt.aprintf(format, ..args))
}

@(private)
oops :: proc(s: ^Syncer, e: Error, what: string) -> (stop: bool) {
	if offline(e) {
		s.pass.offline = true
		append(&s.pass.errors, fmt.aprintf("offline during %s: %s", what, e.message))
		return true
	}
	append(&s.pass.errors, fmt.aprintf("%s: %s%s%s", what, e.code, e.code != "" ? " " : "", e.message))
	return false
}

@(private)
remember :: proc(s: ^Syncer, it: Item) {
	s.st.remote[strings.clone(it.id)] = Remote {
		id      = strings.clone(it.id),
		parent  = strings.clone(it.parent_id),
		name    = strings.clone(it.name),
		kind    = strings.clone(it.kind),
		hash    = strings.clone(it.content_hash),
		seq     = it.seq,
		size    = it.size,
		trashed = it.trashed_at != "",
	}
}

@(private)
set_base :: proc(s: ^Syncer, p, id, kind, hash: string) {
	size, mt: i64
	if kind == "file" {
		size, mt = stat_mtime(fmt.tprintf("%s/%s", s.root, p))
	}
	s.st.base[strings.clone(p)] = Base {
		id   = strings.clone(id),
		kind = kind,
		hash = strings.clone(hash),
		size = size,
		mtime = mt,
	}
	save_state(s.spath, &s.st)
}

@(private)
drop_base :: proc(s: ^Syncer, p: string) {
	delete_key(&s.st.base, p)
	save_state(s.spath, &s.st)
}

// rebase moves every base entry under `from` to sit under `to`.
@(private)
rebase :: proc(s: ^Syncer, from, to: string) {
	moves := make([dynamic]string, context.temp_allocator)
	for k, _ in s.st.base {
		if k == from || under(k, from) {
			append(&moves, k)
		}
	}
	for k in moves {
		v := s.st.base[k]
		delete_key(&s.st.base, k)
		np := strings.concatenate({to, k[len(from):]})
		s.st.base[np] = v
	}
	save_state(s.spath, &s.st)
}

@(private)
parent_id :: proc(s: ^Syncer, p: string) -> (id: string, ok: bool) {
	dir := parent_of(p)
	if dir == "" {
		return "", true
	}
	if b, bok := s.st.base[dir]; bok && b.kind == "folder" {
		return b.id, true
	}
	if r, rok := s.rpath[dir]; rok && r.kind == "folder" {
		return r.id, true
	}
	return "", false
}

@(private)
local_taken :: proc(name: string, data: rawptr) -> bool {
	full := (^string)(data)^
	return os.exists(fmt.tprintf("%s/%s", parent_of(full), name))
}

// sync_once runs one pass for one identity and returns what it did.
sync_once :: proc(cfg: ^Config, id: ^Identity, dry_run := false) -> (pass: ^Pass) {
	pass = new(Pass)
	pass.dry_run = dry_run
	s := Syncer {
		c     = client_for(cfg, id),
		root  = id.root,
		spath = strings.clone(state_path(cfg, id)),
		pass  = pass,
	}
	s.st = load_state(s.spath)
	os.make_directory_all(s.root)

	// 1. Pull the feed into the mirror.
	items, e := changes(&s.c, s.st.cursor)
	if failed(e) {
		if offline(e) {
			pass.offline = true
			// Offline: say what is queued, which is every local change
			// against base. Nothing is lost by not being able to send it.
			s.local = scan(s.root, &s.st)
			queued(&s)
			return
		}
		append(&pass.errors, fmt.aprintf("reading the feed: %s", e.message))
		return
	}
	for it in items {
		remember(&s, it)
		s.st.cursor = max(s.st.cursor, it.seq)
	}
	if !dry_run {
		save_state(s.spath, &s.st)
	}

	s.rpath, s.idp = remote_paths(&s.st)
	s.local = scan(s.root, &s.st)

	// 2. Moves first, so an edit inside a renamed folder is an edit and not a
	// delete plus a create.
	if !dry_run {
		if remote_moves(&s) || local_moves(&s) {
			s.rpath, s.idp = remote_paths(&s.st)
			s.local = scan(s.root, &s.st)
		}
	}
	if pass.offline {
		return
	}

	// 3. Everything else, path by path.
	reconcile(&s)
	return
}

// queued lists the local changes base does not have, for an offline pass.
@(private)
queued :: proc(s: ^Syncer) {
	keys := slice.map_keys(s.local, context.temp_allocator) or_else nil
	slice.sort(keys)
	for p in keys {
		l := s.local[p]
		b, hb := s.st.base[p]
		if !hb {
			act(s, "queued: upload new %s %s", l.kind, p)
		} else if l.kind == "file" && l.hash != b.hash {
			act(s, "queued: upload change %s", p)
		}
	}
	bkeys := slice.map_keys(s.st.base, context.temp_allocator) or_else nil
	slice.sort(bkeys)
	for p in bkeys {
		if _, ok := s.local[p]; !ok {
			act(s, "queued: delete %s", p)
		}
	}
}

// remote_moves: something was renamed or moved on the server, and the local
// copy is still what base says. Rename locally to follow.
@(private)
remote_moves :: proc(s: ^Syncer) -> (moved: bool) {
	for _ in 0 ..< 10000 {
		if !remote_move_one(s) {
			break
		}
		moved = true
	}
	return
}

@(private)
remote_move_one :: proc(s: ^Syncer) -> bool {
	keys := slice.map_keys(s.st.base, context.temp_allocator) or_else nil
	slice.sort_by(keys, proc(a, b: string) -> bool {return depth_of(a) < depth_of(b) || depth_of(a) == depth_of(b) && a < b})
	for oldp in keys {
		b := s.st.base[oldp]
		newp, live := s.idp[b.id]
		if !live || newp == oldp {
			continue
		}
		l, hl := s.local[oldp]
		if !hl || l.kind != b.kind || (b.kind == "file" && l.hash != b.hash) {
			continue // changed locally too: leave it to reconcile
		}
		if os.exists(fmt.tprintf("%s/%s", s.root, newp)) {
			continue
		}
		os.make_directory_all(fmt.tprintf("%s/%s", s.root, parent_of(newp)))
		if os.rename(fmt.tprintf("%s/%s", s.root, oldp), fmt.tprintf("%s/%s", s.root, newp)) != nil {
			continue
		}
		rebase(s, oldp, newp)
		s.pass.moved_local += 1
		act(s, "moved locally %s -> %s", oldp, newp)
		// A move rewrites the paths under it, so start over with fresh
		// keys: the files inside a renamed folder may have moved too.
		s.local = scan(s.root, &s.st)
		return true
	}
	return false
}

// local_moves: a base path is gone locally, the server still has it as base
// says, and a path base does not know holds the same thing. That is a rename
// or a move made here; send it as one, so the server keeps the item's id,
// history and shares instead of a delete and an unrelated new file.
@(private)
local_moves :: proc(s: ^Syncer) -> (moved: bool) {
	for _ in 0 ..< 10000 {
		if s.pass.offline || !local_move_one(s) {
			break
		}
		moved = true
	}
	return
}

@(private)
local_move_one :: proc(s: ^Syncer) -> bool {
	keys := slice.map_keys(s.st.base, context.temp_allocator) or_else nil
	slice.sort_by(keys, proc(a, b: string) -> bool {return depth_of(a) < depth_of(b) || depth_of(a) == depth_of(b) && a < b})
	for oldp in keys {
		b := s.st.base[oldp]
		if _, hl := s.local[oldp]; hl {
			continue
		}
		r, hr := s.rpath[oldp]
		if !hr || r.id != b.id || (b.kind == "file" && r.hash != b.hash) {
			continue
		}
		newp := find_moved(s, oldp, b)
		if newp == "" {
			continue
		}
		pid, pok := parent_id(s, newp)
		if !pok {
			continue // moved into a folder the server does not have yet
		}
		if s.stuck[oldp] {
			continue
		}
		it, e := move(&s.c, b.id, pid, base_name(newp), r.seq)
		if failed(e) {
			oops(s, e, fmt.tprintf("moving %s", oldp))
			if s.stuck == nil {
				s.stuck = make(map[string]bool, context.temp_allocator)
			}
			s.stuck[oldp] = true
			continue
		}
		remember(s, it)
		rebase(s, oldp, newp)
		s.pass.moved_remote += 1
		act(s, "moved on server %s -> %s", oldp, newp)
		s.rpath, s.idp = remote_paths(&s.st)
		return true
	}
	return false
}

@(private)
find_moved :: proc(s: ^Syncer, oldp: string, b: Base) -> string {
	cands := make([dynamic]string, context.temp_allocator)
	best, best_found := "", 0
	for p, l in s.local {
		if l.kind != b.kind {
			continue
		}
		if _, known := s.st.base[p]; known {
			continue
		}
		if _, onserver := s.rpath[p]; onserver {
			continue
		}
		if b.kind == "file" {
			if l.hash == b.hash {
				append(&cands, p)
			}
			continue
		}
		// A folder matches when most of what base had under the old path is
		// under the candidate, unchanged. "Most" rather than "all", because
		// a rename of a folder and of a file inside it in the same offline
		// stretch is ordinary; the file is matched on its own afterwards.
		total, found := 0, 0
		for bp, bb in s.st.base {
			if !under(bp, oldp) {
				continue
			}
			total += 1
			np := strings.concatenate({p, bp[len(oldp):]}, context.temp_allocator)
			if nl, ok := s.local[np]; ok && nl.kind == bb.kind && nl.hash == bb.hash {
				found += 1
			}
		}
		if total > 0 && found * 2 >= total {
			append(&cands, p)
			if found > best_found {
				best_found, best = found, p
			}
		}
	}
	if best != "" && b.kind == "folder" {
		return best
	}
	if len(cands) == 0 {
		return ""
	}
	// Prefer a candidate with the same name (a move) or the same folder (a
	// rename); otherwise the first, in a stable order.
	slice.sort(cands[:])
	for c in cands {
		if base_name(c) == base_name(oldp) || parent_of(c) == parent_of(oldp) {
			return c
		}
	}
	// An empty folder elsewhere with another name is too weak a match.
	if b.kind == "folder" {
		return ""
	}
	return cands[0]
}

@(private)
Plan :: enum {
	None,
	Agree,
	Upload_New,
	Upload_Change,
	Download,
	Conflict,
	Mkdir_Remote,
	Mkdir_Local,
	Delete_Local,
	Trash_Remote,
	Drop,
}

@(private)
plan_for :: proc(s: ^Syncer, p: string) -> Plan {
	b, hb := s.st.base[p]
	l, hl := s.local[p]
	r, hr := s.rpath[p]
	switch {
	case hl && hr:
		if l.kind != r.kind {
			return .Conflict
		}
		if l.kind == "folder" || l.hash == r.hash {
			return .Agree
		}
		lchanged := !hb || l.hash != b.hash
		rchanged := !hb || r.id != b.id || r.hash != b.hash
		if lchanged && !rchanged {
			return .Upload_Change
		}
		if rchanged && !lchanged {
			return .Download
		}
		return .Conflict
	case hl && !hr:
		if l.kind == "folder" {
			if !hb || keep_local_folder(s, p) {
				return .Mkdir_Remote
			}
			return .Delete_Local
		}
		if !hb || l.hash != b.hash {
			return .Upload_New // new, or edited here while deleted there: the edit wins
		}
		return .Delete_Local
	case !hl && hr:
		if r.kind == "folder" {
			if !hb || keep_remote_folder(s, p) {
				return .Mkdir_Local
			}
			return .Trash_Remote
		}
		if !hb || r.id != b.id || r.hash != b.hash {
			return .Download // new there, or edited there while deleted here
		}
		return .Trash_Remote
	case hb:
		return .Drop
	}
	return .None
}

// A folder deleted on the server but holding something here the server never
// had is kept, and re-created there.
@(private)
keep_local_folder :: proc(s: ^Syncer, dir: string) -> bool {
	for p, l in s.local {
		if !under(p, dir) {
			continue
		}
		b, hb := s.st.base[p]
		if !hb || (l.kind == "file" && l.hash != b.hash) {
			return true
		}
	}
	return false
}

@(private)
keep_remote_folder :: proc(s: ^Syncer, dir: string) -> bool {
	for p, r in s.rpath {
		if !under(p, dir) {
			continue
		}
		b, hb := s.st.base[p]
		if !hb || r.id != b.id || (r.kind == "file" && r.hash != b.hash) {
			return true
		}
	}
	return false
}

@(private)
reconcile :: proc(s: ^Syncer) {
	all := make(map[string]bool, context.temp_allocator)
	for p, _ in s.local {all[p] = true}
	for p, _ in s.rpath {all[p] = true}
	for p, _ in s.st.base {all[p] = true}
	paths := slice.map_keys(all, context.temp_allocator) or_else nil
	// Parents before children for creating; children before parents for
	// deleting, so a folder is only removed once it is empty.
	slice.sort_by(paths, proc(a, b: string) -> bool {return depth_of(a) < depth_of(b) || depth_of(a) == depth_of(b) && a < b})

	plans := make(map[string]Plan, context.temp_allocator)
	for p in paths {
		plans[p] = plan_for(s, p)
	}

	if s.pass.dry_run {
		for p in paths {
			pl := plans[p]
			if pl != .None && pl != .Agree && pl != .Drop {
				act(s, "would %v %s", pl, p)
			}
		}
		return
	}

	for p in paths {
		if s.pass.offline {
			return
		}
		switch plans[p] {
		case .Agree:
			r := s.rpath[p]
			b, hb := s.st.base[p]
			if !hb || b.id != r.id || b.hash != r.hash {
				set_base(s, p, r.id, r.kind, r.hash)
				s.pass.agreed += 1
			}
		case .Upload_New:
			do_upload(s, p, "", 0)
		case .Upload_Change:
			r := s.rpath[p]
			do_upload(s, p, r.id, r.seq)
		case .Download:
			do_download(s, p)
		case .Conflict:
			do_conflict(s, p)
		case .Mkdir_Remote:
			do_mkdir_remote(s, p)
		case .Mkdir_Local:
			r := s.rpath[p]
			os.make_directory_all(fmt.tprintf("%s/%s", s.root, p))
			set_base(s, p, r.id, "folder", "")
			s.pass.folders += 1
			act(s, "created folder locally %s", p)
		case .Delete_Local, .Trash_Remote, .Drop, .None:
		}
	}

	#reverse for p in paths {
		if s.pass.offline {
			return
		}
		switch plans[p] {
		case .Delete_Local:
			do_delete_local(s, p)
		case .Trash_Remote:
			// Inside a folder that is itself being trashed: one trashing of
			// the folder takes it, so a restore brings the whole tree back.
			if parent := parent_of(p); parent != "" && plans[parent] == .Trash_Remote {
				drop_base(s, p)
			} else {
				do_trash_remote(s, p)
			}
		case .Drop:
			drop_base(s, p)
		case .None, .Agree, .Upload_New, .Upload_Change, .Download, .Conflict, .Mkdir_Remote, .Mkdir_Local:
		}
	}
}

@(private)
do_upload :: proc(s: ^Syncer, p, item: string, base_seq: i64) {
	pid, ok := parent_id(s, p)
	if !ok {
		append(&s.pass.errors, fmt.aprintf("upload %s: its folder is not on the server yet", p))
		return
	}
	prog: Progress
	it, h, e := upload_file(&s.c, fmt.tprintf("%s/%s", s.root, p), pid, base_name(p), item, base_seq, &prog)
	s.pass.sent_chunks += prog.sent_chunks
	s.pass.skipped_chunks += prog.skipped_chunks
	s.pass.sent_bytes += prog.sent_bytes
	if failed(e) {
		// PT409: the server moved on since we looked. Not an error: the next
		// pass pulls the change and this becomes a conflict, kept both ways.
		oops(s, e, fmt.tprintf("uploading %s", p))
		return
	}
	remember(s, it)
	set_base(s, p, it.id, "file", h.hash)
	s.pass.uploaded += 1
	act(
		s,
		"uploaded %s (%d of %d chunks sent, %d already there)",
		p,
		prog.sent_chunks,
		len(h.chunks),
		prog.skipped_chunks,
	)
}

@(private)
do_download :: proc(s: ^Syncer, p: string) {
	r := s.rpath[p]
	full := fmt.tprintf("%s/%s", s.root, p)
	// Last look before overwriting: if the file changed since the scan, do
	// not clobber it; the next pass will see a conflict.
	if l, hl := s.local[p]; hl {
		size, mt := stat_mtime(full)
		if size != l.size || mt != l.mtime {
			append(&s.pass.errors, fmt.aprintf("%s changed during the pass; left for the next one", p))
			return
		}
	}
	it, ge := get_item(&s.c, r.id)
	if failed(ge) {
		oops(s, ge, fmt.tprintf("downloading %s", p))
		return
	}
	v, ve := current_version(&s.c, it)
	if failed(ve) {
		oops(s, ve, fmt.tprintf("downloading %s", p))
		return
	}
	os.make_directory_all(parent_of(full))
	if e := download_to(&s.c, s.c.identity, v, full); failed(e) {
		oops(s, e, fmt.tprintf("downloading %s", p))
		return
	}
	remember(s, it)
	set_base(s, p, it.id, "file", v.content_hash)
	s.pass.downloaded += 1
	act(s, "downloaded %s", p)
}

// do_conflict keeps both. The server's version keeps the name, because other
// devices already have it under that name; this device's version is renamed
// beside it, uploaded as a new file, and so reaches every device too.
@(private)
do_conflict :: proc(s: ^Syncer, p: string) {
	full := fmt.tprintf("%s/%s", s.root, p)
	newname := conflict_name(base_name(p), s.c.device, local_taken, &full)
	newp := join(parent_of(p), newname)
	if os.rename(full, fmt.tprintf("%s/%s", s.root, newp)) != nil {
		append(&s.pass.errors, fmt.aprintf("conflict on %s: could not set the local copy aside", p))
		return
	}
	s.pass.conflicts += 1
	act(s, "conflict on %s: kept this device's version as %s", p, newname)
	l := s.local[p]
	delete_key(&s.local, p)
	s.local[newp] = l
	drop_base(s, p)
	r := s.rpath[p]
	if r.kind == "folder" {
		os.make_directory_all(full)
		set_base(s, p, r.id, "folder", "")
	} else {
		do_download(s, p)
	}
	if l.kind == "file" {
		do_upload(s, newp, "", 0)
	}
	// A folder set aside is uploaded, contents and all, on the next pass.
}

@(private)
do_mkdir_remote :: proc(s: ^Syncer, p: string) {
	pid, ok := parent_id(s, p)
	if !ok {
		append(&s.pass.errors, fmt.aprintf("folder %s: its parent is not on the server yet", p))
		return
	}
	it, e := mkdir(&s.c, pid, base_name(p))
	if failed(e) {
		oops(s, e, fmt.tprintf("creating folder %s", p))
		return
	}
	remember(s, it)
	set_base(s, p, it.id, "folder", "")
	s.pass.folders += 1
	act(s, "created folder on server %s", p)
}

@(private)
do_delete_local :: proc(s: ^Syncer, p: string) {
	full := fmt.tprintf("%s/%s", s.root, p)
	b := s.st.base[p]
	if b.kind == "folder" {
		// Only an empty folder goes; anything left in it was kept on purpose
		// (see keep_local_folder) or arrived during the pass.
		entries, _ := os.read_all_directory_by_path(full, context.temp_allocator)
		if len(entries) > 0 {
			return
		}
		os.remove(full)
	} else {
		size, mt := stat_mtime(full)
		if size != b.size || mt != b.mtime {
			append(&s.pass.errors, fmt.aprintf("%s changed during the pass; not deleted", p))
			return
		}
		os.remove(full)
	}
	drop_base(s, p)
	s.pass.deleted_local += 1
	act(s, "deleted locally %s (it is in the server's trash)", p)
}

@(private)
do_trash_remote :: proc(s: ^Syncer, p: string) {
	if os.exists(fmt.tprintf("%s/%s", s.root, p)) {
		return // re-created locally during this pass
	}
	r := s.rpath[p]
	if r.kind == "folder" {
		// A parent already trashed took this with it.
		if pr, ok := s.st.remote[r.id]; ok && pr.trashed {
			drop_base(s, p)
			return
		}
	}
	if e := trash(&s.c, r.id); failed(e) {
		if e.code != "PT404" {
			oops(s, e, fmt.tprintf("trashing %s", p))
			return
		}
	}
	// Mark it and everything under it trashed in the mirror; the feed will
	// say so too, but children of a trashed folder must not be trashed again.
	for id, &x in s.st.remote {
		if id == r.id {
			x.trashed = true
		}
	}
	for q, rr in s.rpath {
		if under(q, p) {
			if x, ok := &s.st.remote[rr.id]; ok {
				x.trashed = true
			}
		}
	}
	drop_base(s, p)
	s.pass.trashed_remote += 1
	act(s, "moved to the server's trash %s", p)
}
