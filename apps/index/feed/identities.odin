// Which identities this device holds, and where each one's data lives.
//
// The index never invents an identity and never guesses which one a thing
// belongs to. An identity is known from, in order of authority:
//
//	1. the cloud: the person's own (unscoped) session lists them
//	   (cloudkit.identities), cached in <index root>/<handle>/identity
//	2. mailcore's palmframe.conf, which `mailcore palm sync` writes with each
//	   identity's id, handle, name, kind, colour and address
//	3. what an earlier run cached in <index root>/<handle>/identity
//	4. local data folders named by handle (~/Drive/<h>, ~/Notes/<h>, the
//	   DAV cache, browser profiles, track): with no account at all, each
//	   is an identity of its own, named after its handle — local-only mode
//
// Data in a folder that names no identity (the notes app's "local"
// notebook, calendar's device-only events.tsv, track's "default") is not
// indexed, and `index status` says so: product.md P3, nothing defaults
// across identities.
package indexfeed

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import ic "../core"

Paths :: struct {
	index:   string, // the index root
	mail:    string, // mailcore's Maildir root (palmframe.conf lives here)
	drive:   string, // the parent of ~/Drive/<handle>
	notes:   string, // the parent of ~/Notes/<handle>
	dav:     string, // the DAV cache: <dav>/<handle>/{calendar,addressbook}
	browser: string, // <browser>/<handle>/{history.jsonl,bookmarks.json}
	track:   string, // <track>/<handle>/*.md
}

@(private)
env_or :: proc(name, def: string) -> string {
	if v := os.get_env(name, context.temp_allocator); v != "" {
		return strings.clone(v)
	}
	return def
}

// paths_default reads the same environment variables the apps themselves
// read, so the index looks exactly where they write.
paths_default :: proc() -> Paths {
	home := os.get_env("HOME", context.temp_allocator)
	data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if data == "" {
		data = fmt.tprintf("%s/.local/share", home)
	}
	return Paths {
		index   = ic.index_root(),
		mail    = env_or("PALM_MAIL_DIR", fmt.aprintf("%s/palmy-mail", data)),
		drive   = env_or("PALM_DRIVE_DIR", fmt.aprintf("%s/Drive", home)),
		notes   = env_or("PALM_NOTES_ROOT", fmt.aprintf("%s/Notes", home)),
		dav     = env_or("PALM_DAV_CACHE", fmt.aprintf("%s/palm/dav", data)),
		browser = env_or("PALM_BROWSER_HOME", fmt.aprintf("%s/palmframe/browser", data)),
		track   = env_or("PALM_TRACK_ROOT", fmt.aprintf("%s/palmy-track", data)),
	}
}

Ident :: struct {
	using info: ic.Identity,
	mail_dir:   string, // <mail>/<address>, "" if none
	source:     string, // where the identity came from: cloud, mail, cache, local
}

// PALETTE is the order colours are handed to identities that came with
// none (local-only mode), the same eight hues shell.md lists. Red is
// reserved for overdue and destructive.
PALETTE := [?]string{"teal", "blue", "amber", "violet", "rose", "emerald", "indigo", "slate"}

@(private)
find :: proc(xs: ^[dynamic]Ident, handle: string) -> ^Ident {
	for &x in xs {
		if x.handle == handle {
			return &x
		}
	}
	return nil
}

@(private)
fill :: proc(dst: ^Ident, src: ic.Identity) {
	if dst.id == "" {dst.id = src.id}
	if dst.name == "" || dst.name == dst.handle {dst.name = src.name}
	if dst.kind == "" {dst.kind = src.kind}
	if dst.color == "" {dst.color = src.color}
	if dst.address == "" {dst.address = src.address}
}

// read_palmframe_conf parses mailcore's identity blocks.
read_palmframe_conf :: proc(mail_root: string, out: ^[dynamic]Ident) {
	data, err := os.read_entire_file_from_path(fmt.tprintf("%s/palmframe.conf", mail_root), context.temp_allocator)
	if err != nil {
		return
	}
	cur: Ident
	in_block := false
	flush :: proc(out: ^[dynamic]Ident, cur: ^Ident, mail_root: string) {
		if cur.handle == "" || !ic.handle_ok(cur.handle) {
			return
		}
		x := find(out, cur.handle)
		if x == nil {
			append(out, Ident{info = {handle = cur.handle}, source = "mail"})
			x = &out[len(out) - 1]
		}
		fill(x, cur.info)
		if cur.mail_dir != "" && x.mail_dir == "" {
			x.mail_dir = fmt.aprintf("%s/%s", mail_root, cur.mail_dir)
		}
	}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if l == "[identity]" {
			if in_block {
				flush(out, &cur, mail_root)
			}
			cur = {}
			in_block = true
			continue
		}
		if strings.has_prefix(l, "[") {
			if in_block {
				flush(out, &cur, mail_root)
			}
			in_block = false
			continue
		}
		if !in_block {
			continue
		}
		eq := strings.index_byte(l, '=')
		if eq < 0 {
			continue
		}
		k := strings.trim_space(l[:eq])
		v := strings.clone(strings.trim_space(l[eq + 1:]))
		switch k {
		case "id":
			cur.id = v
		case "handle":
			cur.handle = v
		case "name":
			cur.name = v
		case "kind":
			cur.kind = v
		case "color":
			cur.color = v
		case "address":
			cur.address = v
		case "path":
			if !strings.contains(v, "/") && !strings.contains(v, "..") {
				cur.mail_dir = v
			}
		}
	}
	if in_block {
		flush(out, &cur, mail_root)
	}
}

identity_json :: proc(i: ic.Identity, allocator := context.temp_allocator) -> string {
	q :: proc(s: string) -> string {
		b, _ := json.marshal(s, allocator = context.temp_allocator)
		return string(b)
	}
	return fmt.aprintf(
		"{{\"id\":%s,\"handle\":%s,\"name\":%s,\"kind\":%s,\"color\":%s,\"address\":%s}}\n",
		q(i.id), q(i.handle), q(i.name), q(i.kind), q(i.color), q(i.address),
		allocator = allocator,
	)
}

identity_parse :: proc(data: []u8) -> (i: ic.Identity, ok: bool) {
	v, err := json.parse(data, allocator = context.temp_allocator)
	if err != nil {
		return {}, false
	}
	o, isobj := v.(json.Object)
	if !isobj {
		return {}, false
	}
	str :: proc(o: json.Object, k: string) -> string {
		if s, sok := o[k].(json.String); sok {
			return strings.clone(s)
		}
		return ""
	}
	i = ic.Identity {
		id      = str(o, "id"),
		handle  = str(o, "handle"),
		name    = str(o, "name"),
		kind    = str(o, "kind"),
		color   = str(o, "color"),
		address = str(o, "address"),
	}
	return i, ic.handle_ok(i.handle)
}

// read_cached lists the identities that already have an index directory,
// with what their `identity` file says about them.
read_cached :: proc(root: string, out: ^[dynamic]Ident) {
	entries, err := os.read_all_directory_by_path(root, context.temp_allocator)
	if err != nil {
		return
	}
	for e in entries {
		if e.type != .Directory || !ic.handle_ok(e.name) {
			continue
		}
		data, rerr := os.read_entire_file_from_path(fmt.tprintf("%s/%s/identity", root, e.name), context.temp_allocator)
		info := ic.Identity{handle = strings.clone(e.name)}
		if rerr == nil {
			if i, ok := identity_parse(data); ok && i.handle == e.name {
				info = i
			}
		}
		x := find(out, info.handle)
		if x == nil {
			append(out, Ident{info = {handle = info.handle}, source = "cache"})
			x = &out[len(out) - 1]
		}
		fill(x, info)
	}
}

// local_handles lists the handle-named folders under a data root, skipping
// the names apps use for "no identity".
@(private)
local_handles :: proc(dir: string, out: ^[dynamic]string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	for e in entries {
		if e.type != .Directory || !ic.handle_ok(e.name) {
			continue
		}
		switch e.name {
		case "local", "default":
			continue // "no identity", by those apps' own convention
		}
		append(out, strings.clone(e.name, context.temp_allocator))
	}
}

// discover lists the identities on this device. `scope` ($PALM_IDENTITY)
// narrows it to one; nothing about the others is read beyond their folder
// names, and with a scope not even those.
discover :: proc(p: Paths, scope := "", cloud: []ic.Identity = nil) -> [dynamic]Ident {
	out := make([dynamic]Ident)
	for c in cloud {
		if !ic.handle_ok(c.handle) {
			continue
		}
		append(&out, Ident{info = c, source = "cloud"})
	}
	read_palmframe_conf(p.mail, &out)
	read_cached(p.index, &out)
	known := len(out) > 0
	locals := make([dynamic]string, context.temp_allocator)
	local_handles(p.drive, &locals)
	local_handles(p.notes, &locals)
	local_handles(p.dav, &locals)
	local_handles(p.browser, &locals)
	local_handles(p.track, &locals)
	for h in locals {
		if find(&out, h) != nil {
			continue
		}
		if known {
			// With an account, a folder naming no identity of it is not one:
			// `browser` makes "personal" by default whether or not you have
			// an identity called that. Status reports it.
			continue
		}
		append(&out, Ident{info = {handle = strings.clone(h)}, source = "local"})
	}
	// Defaults for what nothing said.
	for &x, i in out {
		if x.name == "" {
			x.name = strings.clone(x.handle)
			if len(x.name) > 0 && x.name[0] >= 'a' && x.name[0] <= 'z' {
				b := transmute([]u8)x.name
				b[0] -= 32
			}
		}
		if x.color == "" {
			x.color = PALETTE[i % len(PALETTE)]
		}
		if x.kind == "" {
			x.kind = "personal"
		}
		if x.mail_dir == "" && x.address != "" && !strings.contains(x.address, "/") {
			d := fmt.aprintf("%s/%s", p.mail, x.address)
			if os.is_dir(d) {
				x.mail_dir = d
			}
		}
	}
	if scope != "" {
		#reverse for x, i in out {
			if x.handle != scope {
				ordered_remove(&out, i)
			}
		}
	}
	return out
}

// unclaimed lists data folders that name no known identity, for status.
unclaimed :: proc(p: Paths, ids: []Ident, allocator := context.temp_allocator) -> [dynamic]string {
	out := make([dynamic]string, allocator)
	check :: proc(out: ^[dynamic]string, ids: []Ident, dir, what: string) {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {
			return
		}
		for e in entries {
			if e.type != .Directory || strings.has_prefix(e.name, ".") {
				continue
			}
			found := false
			for x in ids {
				if x.handle == e.name {
					found = true
				}
			}
			if !found {
				append(out, fmt.tprintf("%s/%s (%s: names no identity)", dir, e.name, what))
			}
		}
	}
	check(&out, ids, p.drive, "drive")
	check(&out, ids, p.notes, "notes")
	check(&out, ids, p.dav, "calendar and contacts")
	check(&out, ids, p.browser, "browser")
	check(&out, ids, p.track, "tasks")
	return out
}

// identities_visible is what a reader (Home, `index search`) may open: the
// identities with an index directory, narrowed by scope. It reads only the
// directory names and each in-scope identity's own `identity` file.
identities_visible :: proc(root: string, scope := "") -> [dynamic]Ident {
	out := make([dynamic]Ident)
	if scope != "" {
		if !ic.handle_ok(scope) {
			return out
		}
		info := ic.Identity{handle = strings.clone(scope)}
		path := fmt.tprintf("%s/%s/identity", root, scope)
		ic.note_open(path)
		if data, err := os.read_entire_file_from_path(path, context.temp_allocator); err == nil {
			if i, ok := identity_parse(data); ok && i.handle == scope {
				info = i
			}
		}
		if os.is_dir(fmt.tprintf("%s/%s", root, scope)) {
			append(&out, Ident{info = info, source = "cache"})
		}
		return out
	}
	read_cached(root, &out)
	// A stable order, so Ctrl 1…n and the colours stay put between runs.
	slice.sort_by(out[:], proc(a, b: Ident) -> bool {return a.handle < b.handle})
	for &x, i in out {
		if x.name == "" {
			x.name = strings.clone(x.handle)
		}
		if x.color == "" {
			x.color = PALETTE[i % len(PALETTE)]
		}
	}
	return out
}
