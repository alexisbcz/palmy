package palm

// Installing and removing: where packages touch the filesystem.
//
// NO INSTALL SCRIPTS. A .palm is files, directories, symlinks and their
// owners and modes, and nothing else: no pre-install, no post-install, no
// triggers. That is a feature, not a gap. It means installing a package can
// be read off its file list, `palm --root` builds a root filesystem on a
// machine that could not run the package's code, `--dry-run` is exactly true,
// and removing a package undoes it completely. What scripts would do is
// either data (a user that must exist is an `install_user` line; a config
// file is a file) or belongs to the system at boot (palm-init), not to the
// package manager at install time.
//
// A transaction runs in phases, and nothing on disk changes until the third:
//
//  1. Stage   fetch every package and check its sha256 against the signed
//             index; open it and check .PKGINFO says what the index said.
//  2. Check   refuse file conflicts: a path two packages both claim, unless
//             it is a directory (directories are shared) or the claimant is
//             the same package being upgraded.
//  3. Remove  packages leaving the world, keeping any path an incoming
//             package is about to write.
//  4. Install in dependency order. Every file is written beside its final
//             place, owned and moded, then renamed over it, so a crash leaves
//             either the old file or the new one. Files of the old version
//             that the new one dropped are removed. The database is saved
//             after each package.
//
// Config files under /etc are protected like apk protects them: if the file
// on disk is not what palm last put there, the new version is written to
// <path>.palm-new and the person's edit is kept; on removal an edited config
// is left in place.
//
// Ownership is applied only when running as root -- or under fakeroot, which
// answers geteuid() with 0 and records the chowns. As an ordinary user palm
// writes files as that user and says nothing: that is `--root` on the host.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

@(private = "file")
Owner_Entry :: struct {
	names: [dynamic]string,
	dir:   bool,
}

Txn :: struct {
	o:         ^Opts,
	db:        ^DB,
	owners:    map[string]^Owner_Entry,
	as_root:   bool,
	dir_cache: map[string]string, // in-root directory -> resolved host path
}

txn_begin :: proc(o: ^Opts, db: ^DB) -> ^Txn {
	t := new(Txn)
	t.o = o
	t.db = db
	t.as_root = is_root()
	for p in db.pkgs {
		owners_add(t, p.name, p.files)
	}
	return t
}

@(private = "file")
owners_add :: proc(t: ^Txn, name: string, files: []File_Rec) {
	for f in files {
		e, has := t.owners[f.path]
		if !has {
			e = new(Owner_Entry)
			e.dir = f.type == .Dir
			t.owners[f.path] = e
		}
		append(&e.names, name)
	}
}

@(private = "file")
owners_drop :: proc(t: ^Txn, name: string, files: []File_Rec) {
	for f in files {
		e, has := t.owners[f.path]
		if !has {
			continue
		}
		for n, i in e.names {
			if n == name {
				unordered_remove(&e.names, i)
				break
			}
		}
	}
}

@(private = "file")
owned :: proc(t: ^Txn, path: string) -> bool {
	e, has := t.owners[path]
	return has && len(e.names) > 0
}

// who_owns answers `palm info --who-owns`.
who_owns :: proc(db: ^DB, path: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for p in db.pkgs {
		for f in p.files {
			if f.path == path {
				append(&out, p.name)
			}
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Paths inside the root
//
// With --root, a symlink inside the target must resolve inside the target:
// an image whose /lib64 is "/usr/lib" must not send glibc's loader into the
// build host's /usr/lib. So parent directories are resolved here, component
// by component, with absolute link targets re-rooted. The final component is
// never followed -- it is the thing being replaced.
// ---------------------------------------------------------------------------

resolve_dir :: proc(t: ^Txn, dir: string) -> (string, Err) {
	if cached, has := t.dir_cache[dir]; has {
		return cached, Err{}
	}
	queue := make([dynamic]string, context.temp_allocator)
	for c in strings.split(dir, "/", context.temp_allocator) {
		if c != "" {
			append(&queue, c)
		}
	}
	cur := ""
	hops := 0
	for len(queue) > 0 {
		comp := queue[0]
		ordered_remove(&queue, 0)
		switch comp {
		case ".":
			continue
		case "..":
			cur = cur == "" ? "" : parent_dir(cur)
			if cur == "/" {cur = ""}
			continue
		}
		next := strings.concatenate({cur, "/", comp}, context.temp_allocator)
		host := rooted(t.o.root, next, context.temp_allocator)
		fi, err := os.stat_do_not_follow_links(host, context.temp_allocator)
		if err == nil && fi.type == .Symlink {
			hops += 1
			if hops > 40 {
				return "", fail(EXIT_FAILED, "too many levels of symbolic links under %s", dir)
			}
			target, lerr := os.read_link(host, context.temp_allocator)
			if lerr != nil {
				return "", fail(EXIT_FAILED, "cannot read the link %s", host)
			}
			if strings.has_prefix(target, "/") {
				cur = ""
			}
			rest := make([dynamic]string, context.temp_allocator)
			for c in strings.split(target, "/", context.temp_allocator) {
				if c != "" {append(&rest, c)}
			}
			append(&rest, ..queue[:])
			queue = rest
			continue
		}
		cur = next
	}
	out := rooted(t.o.root, cur)
	t.dir_cache[strings.clone(dir)] = out
	return out, Err{}
}

host_path :: proc(t: ^Txn, path: string) -> (string, Err) {
	d, e := resolve_dir(t, parent_dir(path))
	if !ok(e) {
		return "", e
	}
	return strings.concatenate({d, "/", base_name(path)}, context.temp_allocator), Err{}
}

@(private = "file")
protected :: proc(path: string) -> bool {
	return strings.has_prefix(path, "/etc/")
}

@(private = "file")
apply_meta :: proc(t: ^Txn, path: string, mode: u32, uid, gid: int, is_link := false) {
	if t.as_root {
		// Ignored failures are deliberate only when not root; as root a
		// failed chown is worth a warning.
		if !set_owner(path, uid, gid) {
			warn("cannot chown %s to %d:%d", path, uid, gid)
		}
	}
	if !is_link {
		// chmod after chown: chown clears setuid and setgid bits.
		set_mode(path, mode)
	}
}

// ---------------------------------------------------------------------------
// Staging
// ---------------------------------------------------------------------------

Staged :: struct {
	change: Change,
	data:   []byte, // the verified .palm
	paths:  []File_Rec, // type and path only, for the conflict check
}

stage :: proc(t: ^Txn, changes: []Change, steps: int = 0) -> ([]Staged, Err) {
	out := make([dynamic]Staged)
	for c, i in changes {
		progress("fetch", c.new.name, c.new.version, i + 1, steps)
		data, e := fetch_package(t.o, c.new)
		if !ok(e) {
			return nil, e
		}
		raw, okz := gzip_decompress(data)
		if !okz {
			return nil, fail(EXIT_FAILED, "%s is not a valid .palm (gzip)", c.new.filename)
		}
		entries, te := tar_read(raw, context.temp_allocator)
		if !ok(te) {
			delete(raw)
			return nil, fail(te.code, "%s: %s", c.new.filename, te.msg)
		}
		if len(entries) == 0 || entries[0].path != ".PKGINFO" {
			delete(raw)
			return nil, fail(EXIT_FAILED, "%s: the first member is not .PKGINFO", c.new.filename)
		}
		recs := parse_records(string(entries[0].data), context.temp_allocator)
		info, ie := pkg_from_record(len(recs) > 0 ? recs[0] : nil, context.temp_allocator)
		if !ok(ie) || info.name != c.new.name || info.version != c.new.version {
			delete(raw)
			return nil, fail(EXIT_REFUSED, "%s: its .PKGINFO does not match the index (%s-%s); refusing", c.new.filename, info.name, info.version)
		}
		paths := make([dynamic]File_Rec)
		for en in entries[1:] {
			append(&paths, File_Rec{path = strings.clone(en.path), type = en.type})
		}
		delete(raw)
		append(&out, Staged{c, data, paths[:]})
	}
	return out[:], Err{}
}

// check_conflicts is phase 2: a path claimed by two packages is refused
// unless both claims are directories or the claims are the same package.
check_conflicts :: proc(t: ^Txn, staged: []Staged, removing: []^Pkg) -> Err {
	leaving := make(map[string]bool, context.temp_allocator)
	for p in removing {
		leaving[p.name] = true
	}
	for s in staged {
		leaving[s.change.new.name] = true // its old files are being replaced
	}
	Claim :: struct {
		name: string,
		dir:  bool,
	}
	claims := make(map[string]Claim, context.temp_allocator)
	for p in t.db.pkgs {
		if leaving[p.name] {continue}
		for f in p.files {
			if _, has := claims[f.path]; !has || f.type != .Dir {
				claims[f.path] = Claim{p.name, f.type == .Dir}
			}
		}
	}
	problems := make([dynamic]string, context.temp_allocator)
	for s in staged {
		name := s.change.new.name
		for f in s.paths {
			is_dir := f.type == .Dir
			prev, has := claims[f.path]
			if !has {
				claims[f.path] = Claim{name, is_dir}
				continue
			}
			if prev.name != name && !(prev.dir && is_dir) {
				append(&problems, fmt.tprintf("%s is in both %s and %s", f.path, prev.name, name))
				continue
			}
			if !is_dir {
				claims[f.path] = Claim{name, false}
			}
		}
	}
	if len(problems) > 0 {
		shown := problems[:min(len(problems), 10)]
		more := len(problems) > 10 ? fmt.tprintf("\n  ... and %d more", len(problems) - 10) : ""
		return fail(EXIT_REFUSED, "file conflicts, refusing:\n  %s%s", strings.join(shown, "\n  ", context.temp_allocator), more)
	}
	return Err{}
}

// ---------------------------------------------------------------------------
// Writing a package
// ---------------------------------------------------------------------------

@(private = "file")
write_file :: proc(t: ^Txn, dest: string, data: []byte, mode: u32, uid, gid: int) -> Err {
	tmp := fmt.tprintf("%s/.palm-new.%s", parent_dir(dest), base_name(dest))
	_ = remove_path(tmp, false)
	f, err := os.open(tmp, {.Write, .Create, .Excl, .Trunc}, os.perm_number(0o600))
	if err != nil {
		return fail(EXIT_FAILED, "cannot create %s: %v", tmp, err)
	}
	written := 0
	for written < len(data) {
		n, werr := os.write(f, data[written:])
		if werr != nil || n <= 0 {
			os.close(f)
			_ = remove_path(tmp, false)
			return fail(EXIT_FAILED, "cannot write %s: %v", tmp, werr)
		}
		written += n
	}
	os.close(f)
	apply_meta(t, tmp, mode, uid, gid)
	if !rename_path(tmp, dest) {
		_ = remove_path(tmp, false)
		return fail(EXIT_FAILED, "cannot move %s into place", dest)
	}
	return Err{}
}

// extract writes one staged package and returns its file records.
extract :: proc(t: ^Txn, s: ^Staged) -> ([]File_Rec, Err) {
	old := s.change.old
	old_recs := make(map[string]File_Rec, context.temp_allocator)
	if old != nil {
		for f in old.files {
			old_recs[f.path] = f
		}
	}
	raw, okz := gzip_decompress(s.data)
	if !okz {
		return nil, fail(EXIT_FAILED, "%s: gzip stream failed on second read", s.change.new.filename)
	}
	defer delete(raw)
	entries, te := tar_read(raw, context.temp_allocator)
	if !ok(te) {
		return nil, te
	}
	ids := load_ids(t.o.root)
	recs := make([dynamic]File_Rec)

	for &e in entries[1:] {
		uid, gid := e.uid, e.gid
		if id, has := ids.users[e.uname]; has && e.uname != "" {uid = id}
		if id, has := ids.groups[e.gname]; has && e.gname != "" {gid = id}
		dest, he := host_path(t, e.path)
		if !ok(he) {
			return nil, he
		}
		rec := File_Rec {
			path = strings.clone(e.path),
			type = e.type,
			mode = e.mode,
			uid  = uid,
			gid  = gid,
		}
		fi, lerr := os.stat_do_not_follow_links(dest, context.temp_allocator)
		exists := lerr == nil
		switch e.type {
		case .Dir:
			if exists {
				if fi.type == .Symlink {
					// A directory reached through a link (/lib -> usr/lib):
					// the link's target carries the metadata.
				} else if fi.type != .Directory {
					return nil, fail(EXIT_FAILED, "cannot create the directory %s: a file is in the way", e.path)
				} else {
					apply_meta(t, dest, e.mode, uid, gid)
				}
			} else {
				if !mkdir_p(dest) {
					return nil, fail(EXIT_FAILED, "cannot create %s", dest)
				}
				apply_meta(t, dest, e.mode, uid, gid)
			}
		case .File:
			if exists && fi.type == .Directory {
				return nil, fail(EXIT_FAILED, "cannot write %s: a directory is in the way", e.path)
			}
			rec.sha = sha256_hex(e.data)
			target := dest
			if protected(e.path) && exists && fi.type == .Regular {
				disk, _ := sha256_file_hex(dest, context.temp_allocator)
				prev, had := old_recs[e.path]
				edited := disk != rec.sha && (!had || prev.sha != disk)
				if edited {
					target = fmt.tprintf("%s.palm-new", dest)
					say("  %s has local changes; the new version is %s.palm-new", e.path, e.path)
				}
			}
			if !os.exists(parent_dir(target)) {
				_ = os.make_directory_all(parent_dir(target))
			}
			if err := write_file(t, target, e.data, e.mode, uid, gid); !ok(err) {
				return nil, err
			}
		case .Symlink:
			if exists && fi.type == .Directory {
				return nil, fail(EXIT_FAILED, "cannot replace the directory %s with a symlink", e.path)
			}
			rec.sha = strings.clone(e.link)
			rec.mode = 0o777
			// A symlink under /etc is configuration as much as a file is:
			// /etc/localtime is palmframe-base's link to UTC until the
			// installer (or the person) points it at their zone. Like an
			// edited file, a link retargeted locally is kept; unlike a file
			// there is nothing useful to put beside it as .palm-new.
			if protected(e.path) && exists && fi.type == .Symlink {
				disk, _ := os.read_link(dest, context.temp_allocator)
				prev, had := old_recs[e.path]
				if disk != e.link && (!had || prev.sha != disk) {
					say("  %s points to %s by local choice; kept (the package's link is %s)", e.path, disk, e.link)
					append(&recs, rec)
					continue
				}
			}
			tmp := fmt.tprintf("%s/.palm-new.%s", parent_dir(dest), base_name(dest))
			_ = remove_path(tmp, false)
			if err := os.symlink(e.link, tmp); err != nil {
				return nil, fail(EXIT_FAILED, "cannot create the symlink %s: %v", e.path, err)
			}
			apply_meta(t, tmp, 0o777, uid, gid, is_link = true)
			if !rename_path(tmp, dest) {
				_ = remove_path(tmp, false)
				return nil, fail(EXIT_FAILED, "cannot move the symlink %s into place", e.path)
			}
			clear(&t.dir_cache)
		case .Hardlink:
			src, se := host_path(t, e.link)
			if !ok(se) {
				return nil, se
			}
			rec.sha = strings.clone(e.link)
			tmp := fmt.tprintf("%s/.palm-new.%s", parent_dir(dest), base_name(dest))
			_ = remove_path(tmp, false)
			if err := os.link(src, tmp); err != nil {
				return nil, fail(EXIT_FAILED, "cannot create the hard link %s: %v", e.path, err)
			}
			if !rename_path(tmp, dest) {
				_ = remove_path(tmp, false)
				return nil, fail(EXIT_FAILED, "cannot move the hard link %s into place", e.path)
			}
		}
		append(&recs, rec)
	}
	return recs[:], Err{}
}

// remove_files deletes the given records, deepest first, skipping anything
// another package still owns, anything in `keep`, and edited configs.
@(private = "file")
remove_files :: proc(t: ^Txn, files: []File_Rec, keep: map[string]bool) {
	sorted := slice.clone(files, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: File_Rec) -> bool {return a.path > b.path})
	for f in sorted {
		if keep[f.path] || owned(t, f.path) {
			continue
		}
		host, e := host_path(t, f.path)
		if !ok(e) {
			continue
		}
		if f.type == .File && protected(f.path) {
			if disk, okh := sha256_file_hex(host, context.temp_allocator); okh && disk != f.sha {
				say("  keeping %s: it has local changes", f.path)
				continue
			}
		}
		if f.type == .Dir {
			_ = remove_path(host, true) // fails, rightly, if not empty
		} else {
			_ = remove_path(host, false)
		}
	}
}

remove_package :: proc(t: ^Txn, p: ^Pkg, keep: map[string]bool) -> Err {
	owners_drop(t, p.name, p.files)
	remove_files(t, p.files, keep)
	for q, i in t.db.pkgs {
		if q == p {
			ordered_remove(&t.db.pkgs, i)
			break
		}
	}
	return db_save(t.db)
}

// install_staged is phase 4 for one package.
install_staged :: proc(t: ^Txn, s: ^Staged) -> Err {
	recs, e := extract(t, s)
	if !ok(e) {
		return fail(e.code, "%s: %s", pkg_id(s.change.new), e.msg)
	}
	old := s.change.old
	if old != nil {
		owners_drop(t, old.name, old.files)
	}
	owners_add(t, s.change.new.name, recs)
	if old != nil {
		now := make(map[string]bool, context.temp_allocator)
		for r in recs {
			now[r.path] = true
		}
		gone := make([dynamic]File_Rec, context.temp_allocator)
		for f in old.files {
			if !now[f.path] {
				append(&gone, f)
			}
		}
		remove_files(t, gone[:], nil)
		for q, i in t.db.pkgs {
			if q == old {
				ordered_remove(&t.db.pkgs, i)
				break
			}
		}
	}
	p := new(Pkg)
	p^ = s.change.new^
	p.files = recs
	p.repo = nil
	p.installed = true
	p.filename = ""
	append(&t.db.pkgs, p)

	ids := load_ids(t.o.root)
	for u in p.install_users {
		name := u
		if i := strings.index_byte(u, ':'); i > 0 {name = u[:i]}
		if _, has := ids.users[name]; !has {
			warn("%s expects the user %q, which %s/etc/passwd does not have", p.name, name, t.o.root == "/" ? "" : t.o.root)
		}
	}
	return db_save(t.db)
}

// run_plan carries out phases 1 to 4.
run_plan :: proc(t: ^Txn, plan: Plan) -> Err {
	// Every package is fetched, then each removal and each install is one
	// step: that is the denominator a progress bar divides by.
	steps := 2 * len(plan.changes) + len(plan.remove)
	step := len(plan.changes)
	staged, e := stage(t, plan.changes[:], steps)
	if !ok(e) {
		return e
	}
	if ce := check_conflicts(t, staged, plan.remove[:]); !ok(ce) {
		return ce
	}
	incoming := make(map[string]bool, context.temp_allocator)
	for s in staged {
		for f in s.paths {
			incoming[f.path] = true
		}
	}
	for p in plan.remove {
		step += 1
		progress("remove", p.name, p.version, step, steps)
		if re := remove_package(t, p, incoming); !ok(re) {
			return re
		}
	}
	for &s in staged {
		c := s.change
		step += 1
		if c.old == nil {
			progress("install", c.new.name, c.new.version, step, steps)
		} else if c.old.version == c.new.version {
			progress("reinstall", c.new.name, c.new.version, step, steps)
		} else {
			progress("upgrade", c.new.name, c.new.version, step, steps, c.old.version)
		}
		if ie := install_staged(t, &s); !ok(ie) {
			return ie
		}
	}
	return Err{}
}
