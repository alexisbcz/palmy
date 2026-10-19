// The local copy of a collection, and two-way sync.
//
//	<cache>/<handle>/<kind>/<seg>/
//	    state          one line per fact, tab-separated (see below)
//	    <name>         each object, exactly as the server has it
//
// state:
//	meta  <tab> href <tab> display name <tab> colour <tab> access <tab> owner <tab> components
//	token <tab> sync token
//	item  <tab> name <tab> etag <tab> clean | dirty | deleted
//
// The apps write objects here and mark them dirty; `sync` pushes dirty and
// deleted ones with If-Match, then pulls with the sync token. A push that
// meets a newer server version (412) loses: the server's copy comes back on
// the pull and the local edit is kept beside it as <name>.conflict, so
// nothing a person typed is silently thrown away.
package davclient

import "core:fmt"
import ck "../../../apps/cloudkit"
import "core:os"
import "core:slice"
import "core:strings"

Item_State :: enum u8 {
	Clean,
	Dirty,
	Deleted,
}

Entry :: struct {
	etag:  string,
	state: Item_State,
}

Local :: struct {
	dir:     string,
	remote:  Remote,
	token:   string,
	entries: map[string]Entry,
}

cache_dir :: proc(a: ^Account, handle, kind, seg: string) -> string {
	return fmt.aprintf("%s/%s/%s/%s", a.cache, handle, kind, seg)
}

@(private)
mkdirs :: proc(path: string) {
	_ = ck.make_dirs(path, os.perm(0o700))
}

// local_open reads a collection's copy (empty if there is none yet). The
// remote's metadata, when given, replaces what was stored.
local_open :: proc(dir: string, rm: Remote = {}) -> ^Local {
	l := new(Local)
	l.dir = strings.clone(dir)
	l.entries = make(map[string]Entry, 32)
	l.remote = rm
	data, err := os.read_entire_file_from_path(fmt.tprintf("%s/state", dir), context.temp_allocator)
	if err == nil {
		rest := string(data)
		for line in strings.split_lines_iterator(&rest) {
			cols := strings.split(line, "\t", context.temp_allocator)
			switch cols[0] {
			case "token":
				if len(cols) > 1 {
					l.token = strings.clone(cols[1])
				}
			case "meta":
				if len(cols) >= 7 && rm.href == "" {
					l.remote.href = strings.clone(cols[1])
					l.remote.display_name = strings.clone(cols[2])
					l.remote.color = strings.clone(cols[3])
					l.remote.access = strings.clone(cols[4])
					l.remote.owner = strings.clone(cols[5])
					comps := strings.split(cols[6], ",")
					l.remote.components = comps
				}
			case "item":
				if len(cols) >= 4 {
					st := Item_State.Clean
					if cols[3] == "dirty" {
						st = .Dirty
					} else if cols[3] == "deleted" {
						st = .Deleted
					}
					l.entries[strings.clone(cols[1])] = Entry{strings.clone(cols[2]), st}
				}
			}
		}
	}
	return l
}

local_save :: proc(l: ^Local) -> bool {
	mkdirs(l.dir)
	sb := strings.builder_make(context.temp_allocator)
	clean :: proc(s: string) -> string {
		out, _ := strings.replace_all(s, "\t", " ", context.temp_allocator)
		out, _ = strings.replace_all(out, "\n", " ", context.temp_allocator)
		return out
	}
	fmt.sbprintf(&sb, "meta\t%s\t%s\t%s\t%s\t%s\t%s\n", clean(l.remote.href), clean(l.remote.display_name),
		clean(l.remote.color), clean(l.remote.access), clean(l.remote.owner),
		strings.join(l.remote.components, ",", context.temp_allocator))
	fmt.sbprintf(&sb, "token\t%s\n", clean(l.token))
	names := make([dynamic]string, 0, len(l.entries), context.temp_allocator)
	for name in l.entries {
		append(&names, name)
	}
	slice.sort(names[:])
	for name in names {
		e := l.entries[name]
		st := e.state == .Clean ? "clean" : (e.state == .Dirty ? "dirty" : "deleted")
		fmt.sbprintf(&sb, "item\t%s\t%s\t%s\n", name, e.etag, st)
	}
	tmp := fmt.tprintf("%s/state.tmp", l.dir)
	if os.write_entire_file(tmp, transmute([]u8)strings.to_string(sb)) != nil {
		return false
	}
	return os.rename(tmp, fmt.tprintf("%s/state", l.dir)) == nil
}

// local_items reads every live object: (name, data), sorted by name.
local_items :: proc(l: ^Local, allocator := context.allocator) -> []Item {
	out := make([dynamic]Item, 0, len(l.entries), allocator)
	for name, e in l.entries {
		if e.state == .Deleted {
			continue
		}
		data, err := os.read_entire_file_from_path(fmt.tprintf("%s/%s", l.dir, safe_file(name)), allocator)
		if err != nil {
			continue
		}
		append(&out, Item{strings.clone(name, allocator), strings.clone(e.etag, allocator), string(data)})
	}
	slice.sort_by(out[:], proc(a, b: Item) -> bool {return a.name < b.name})
	return out[:]
}

// safe_file keeps a resource name inside the directory.
safe_file :: proc(name: string) -> string {
	out, _ := strings.replace_all(name, "/", "%2F", context.temp_allocator)
	if out == "state" || out == "state.tmp" || strings.has_prefix(out, ".") {
		return strings.concatenate({"_", out}, context.temp_allocator)
	}
	return out
}

// local_write stores an object locally and marks it for upload.
local_write :: proc(l: ^Local, name, data: string) -> bool {
	mkdirs(l.dir)
	if os.write_entire_file(fmt.tprintf("%s/%s", l.dir, safe_file(name)), transmute([]u8)data) != nil {
		return false
	}
	e := l.entries[name]
	e.state = .Dirty
	if _, has := l.entries[name]; !has {
		l.entries[strings.clone(name)] = e
	} else {
		l.entries[name] = e
	}
	return local_save(l)
}

// local_delete marks an object for deletion on the server.
local_delete :: proc(l: ^Local, name: string) -> bool {
	e, has := l.entries[name]
	if !has {
		return false
	}
	if e.etag == "" {
		// Never reached the server: just forget it.
		delete_key(&l.entries, name)
		os.remove(fmt.tprintf("%s/%s", l.dir, safe_file(name)))
		return local_save(l)
	}
	e.state = .Deleted
	l.entries[name] = e
	return local_save(l)
}

Sync_Stats :: struct {
	pushed:    int,
	pulled:    int,
	removed:   int,
	conflicts: int,
	full:      bool,
}

// sync reconciles one collection: push, then pull.
sync :: proc(a: ^Account, l: ^Local) -> (st: Sync_Stats, err: Error) {
	rm := l.remote
	writable := rm.access != "read"
	// Push.
	names := make([dynamic]string, 0, 8, context.temp_allocator)
	for name, e in l.entries {
		if e.state != .Clean {
			append(&names, name)
		}
	}
	for name in names {
		e := l.entries[name]
		if !writable {
			// A read-only share: local edits cannot go anywhere. Drop them;
			// the pull restores the server's copy.
			e.state = .Clean
			e.etag = ""
			l.entries[name] = e
			continue
		}
		path := fmt.tprintf("%s/%s", l.dir, safe_file(name))
		if e.state == .Deleted {
			status, re := remove(a, rm, name, e.etag)
			if !ok(re) {
				return st, re
			}
			switch status {
			case 204, 200, 404:
				delete_key(&l.entries, name)
				os.remove(path)
				st.pushed += 1
			case 412:
				st.conflicts += 1
				e.state = .Clean
				l.entries[name] = e
			case:
				return st, Error{status, fmt.aprintf("DELETE %s returned %d", name, status)}
			}
			continue
		}
		data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
		if rerr != nil {
			delete_key(&l.entries, name)
			continue
		}
		etag, status, pe := put(a, rm, name, string(data), e.etag)
		if !ok(pe) {
			return st, pe
		}
		switch status {
		case 201, 204, 200:
			if etag == "" {
				// The server stamped it (scheduling): fetch what it stored.
				body, tag, ge := get(a, strings.concatenate({rm.href, percent_encode(name)}, context.temp_allocator))
				if ok(ge) {
					_ = os.write_entire_file(path, transmute([]u8)body)
					etag = tag
				}
			}
			e.etag = strings.clone(etag)
			e.state = .Clean
			l.entries[name] = e
			st.pushed += 1
		case 412:
			st.conflicts += 1
			_ = os.write_entire_file(fmt.tprintf("%s.conflict", path), data)
			e.state = .Clean
			l.entries[name] = e
		case:
			return st, Error{status, fmt.aprintf("PUT %s returned %d", name, status)}
		}
	}
	local_save(l)

	// Pull.
	p, pe := pull(a, rm, l.token)
	if !ok(pe) {
		return st, pe
	}
	st.full = p.full || l.token == ""
	if st.full {
		keep := make(map[string]bool, len(p.changed), context.temp_allocator)
		for it in p.changed {
			keep[it.name] = true
		}
		for name, e in l.entries {
			if !keep[name] && e.state == .Clean {
				append(&names, name)
			}
		}
		for name in names {
			if e, has := l.entries[name]; has && e.state == .Clean && !keep[name] {
				delete_key(&l.entries, name)
				os.remove(fmt.tprintf("%s/%s", l.dir, safe_file(name)))
				st.removed += 1
			}
		}
	}
	mkdirs(l.dir)
	for it in p.changed {
		if e, has := l.entries[it.name]; has && e.state != .Clean {
			continue // a local edit made during this sync wins until next push
		}
		_ = os.write_entire_file(fmt.tprintf("%s/%s", l.dir, safe_file(it.name)), transmute([]u8)it.data)
		l.entries[strings.clone(it.name)] = Entry{strings.clone(it.etag), .Clean}
		st.pulled += 1
	}
	for name in p.deleted {
		if _, has := l.entries[name]; has {
			delete_key(&l.entries, name)
			os.remove(fmt.tprintf("%s/%s", l.dir, safe_file(name)))
			st.removed += 1
		}
	}
	if p.token != "" {
		l.token = p.token
	}
	local_save(l)
	return st, {}
}

// ---------------------------------------------------------------------------
// The list of collections, cached for offline starts
// ---------------------------------------------------------------------------

remotes_save :: proc(a: ^Account, handle, kind: string, list: []Remote) {
	dir := fmt.tprintf("%s/%s/%s", a.cache, handle, kind)
	mkdirs(dir)
	sb := strings.builder_make(context.temp_allocator)
	for rm in list {
		fmt.sbprintf(&sb, "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", rm.href, rm.seg, rm.display_name, rm.color, rm.access, rm.owner,
			strings.join(rm.components, ",", context.temp_allocator))
	}
	_ = os.write_entire_file(fmt.tprintf("%s/collections", dir), transmute([]u8)strings.to_string(sb))
}

remotes_load :: proc(a: ^Account, handle, kind: string) -> []Remote {
	data, err := os.read_entire_file_from_path(fmt.tprintf("%s/%s/%s/collections", a.cache, handle, kind), context.temp_allocator)
	out := make([dynamic]Remote, 0, 4)
	if err != nil {
		return out[:]
	}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		c := strings.split(line, "\t", context.temp_allocator)
		if len(c) < 7 {
			continue
		}
		append(&out, Remote {
			href = strings.clone(c[0]), seg = strings.clone(c[1]), display_name = strings.clone(c[2]),
			color = strings.clone(c[3]), access = strings.clone(c[4]), owner = strings.clone(c[5]),
			components = strings.split(c[6], ","), kind = kind, handle = strings.clone(handle),
		})
	}
	return out[:]
}
