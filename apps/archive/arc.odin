package main

// Reading archives, checking them, and the worker that does anything slow.
//
// Which program reads or writes a given archive is backend.odin's business.
// Through bsdtar, listing is two runs rather than one: `-tf` gives the exact
// names, one per line, and `-tvf` gives the metadata. Parsing names out of the
// verbose listing alone is a trap — `project/docs/release notes.md` has a space
// in it, and so does half of everything a person ever zipped. 7-Zip and unrar
// have technical listings with one `key = value` per line instead.
//
// The procedures the window's worker runs are the same ones the command line
// calls directly (cli.odin): `list_archive`, `extract_entries`,
// `create_archive`. Only the threading is the window's.
//
// Nothing here runs on the frame thread except the pure functions at the top.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import kit "kit:."

Item :: struct {
	name:   string, // full path inside the archive, exactly as stored
	base:   string, // last component
	parent: string, // everything up to and including the final '/'
	dir:    bool,
	link:   bool,
	size:   i64,
	date:   string,
	perms:  string,
	encrypted: bool, // needs the password to extract (as far as the backend can tell)
	bad:    bool,   // refuses to extract: see `why`
	why:    string,
}

// ---------------------------------------------------------------------------
// Safety
//
// A tar entry is a path chosen by whoever built the archive, and extraction
// writes it under a directory chosen by the user. The two facts together are
// the oldest trick in the book: `../../.ssh/authorized_keys`. Every name is
// checked before it is offered, and anything that escapes — or is a symlink,
// which can escape after the fact — is marked and excluded.
// ---------------------------------------------------------------------------

// check_name returns why an entry must not be extracted, or "" when it is safe.
check_name :: proc(name: string, is_link: bool) -> string {
	if name == "" {
		return "empty name"
	}
	if name[0] == '/' {
		return "absolute path — would write outside the destination"
	}
	if len(name) >= 2 && name[1] == ':' {
		return "drive-letter path — would write outside the destination"
	}
	if strings.contains(name, "\\") {
		return "backslash in the name — ambiguous separator"
	}

	// Walk the segments and keep a depth. Any point at which the depth would
	// go negative is a step above the destination directory.
	depth := 0
	rest := name
	for len(rest) > 0 {
		seg := rest
		if i := strings.index_byte(rest, '/'); i >= 0 {
			seg = rest[:i]
			rest = rest[i + 1:]
		} else {
			rest = ""
		}
		switch seg {
		case "", ".":
		case "..":
			depth -= 1
			if depth < 0 {
				return "“..” escapes the destination directory"
			}
		case:
			depth += 1
		}
	}
	if is_link {
		return "symbolic link — skipped, a link can point anywhere"
	}
	return ""
}

split_parent :: proc(name: string) -> (parent, base: string) {
	n := name
	trailing := strings.has_suffix(n, "/")
	if trailing {
		n = n[:len(n) - 1]
	}
	if i := strings.last_index_byte(n, '/'); i >= 0 {
		return n[:i + 1], n[i + 1:]
	}
	return "", n
}

// ---------------------------------------------------------------------------
// Parsing bsdtar
// ---------------------------------------------------------------------------

// parse_verbose pulls size and date out of one `-tvf` line. The name is taken
// from the matching `-tf` line instead, so nothing here has to cope with
// spaces.
//
//	drwxr-xr-x  0 alex   alex        0 Oct  4 12:17 project/
//	-rw-r--r--  0 alex   alex    54038 Oct  4 12:17 project/src/data.txt
parse_verbose :: proc(line: string) -> (perms: string, size: i64, date: string, ok: bool) {
	f := strings.fields(line, context.temp_allocator)
	if len(f) < 8 {
		return "", 0, "", false
	}
	perms = f[0]
	sz, good := parse_i64(f[4])
	if !good {
		return "", 0, "", false
	}
	date = fmt.tprintf("%s %s %s", f[5], f[6], f[7])
	return perms, sz, date, true
}

parse_i64 :: proc(s: string) -> (i64, bool) {
	if s == "" {
		return 0, false
	}
	v: i64
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		v = v * 10 + i64(s[i] - '0')
	}
	return v, true
}

// list_archive reads an archive into Items, through whichever installed
// program reads this format (backend.odin). It runs on the worker thread, or
// directly from the command line.
list_archive :: proc(path: string, password := "") -> (items: []Item, err: string, fail: Fail) {
	kind := kind_of(path)
	if password != "" && !can_encrypt(kind) {
		return nil, fmt.aprintf("%s has no encryption; a password means nothing to it", KIND_NAMES[kind]), .Failed
	}
	tool, why := reader_for(kind, password != "", tools())
	if tool == .None {
		return nil, strings.clone(why), .Unavailable
	}
	return list_with(tool, path, password)
}

// Staged is what an extraction would do, decided before anything is written:
// the entries it would write, the ones the safety check refused, and the
// files already at the destination.
Staged :: struct {
	names:     [dynamic]string, // heap clones, in archive order
	refused:   [dynamic]int,    // indices into the items
	hit:       int,             // files that already exist under dest
	encrypted: int,             // files that need the password
}

// wanted says whether an entry is picked by a set of picks: its own name, or
// a folder (`name/`) above it. No picks means everything.
wanted :: proc(picks: []string, name: string) -> bool {
	if len(picks) == 0 {
		return true
	}
	for m in picks {
		if m == name {
			return true
		}
		folder := strings.has_suffix(m, "/") ? m : fmt.tprintf("%s/", m)
		if strings.has_prefix(name, folder) || name == folder {
			return true
		}
	}
	return false
}

// stage_names is the one place an extraction is decided, for the window's
// confirmation dialog and for `archive extract` alike.
stage_names :: proc(items: []Item, picks: []string, dest: string) -> (s: Staged) {
	s.names = make([dynamic]string)
	s.refused = make([dynamic]int)
	for it, i in items {
		if !wanted(picks, it.name) {
			continue
		}
		if it.bad {
			append(&s.refused, i)
			continue
		}
		append(&s.names, strings.clone(it.name))
		if !it.dir {
			if os.exists(fmt.tprintf("%s/%s", dest, it.name)) {
				s.hit += 1
			}
			if it.encrypted {
				s.encrypted += 1
			}
		}
	}
	return
}

staged_free :: proc(s: ^Staged) {
	for n in s.names {delete(n)}
	delete(s.names)
	delete(s.refused)
	s^ = {}
}

free_items :: proc(items: []Item) {
	for it in items {
		delete(it.name)
		delete(it.base)
		delete(it.parent)
		delete(it.date)
		delete(it.perms)
		delete(it.why)
	}
	delete(items)
}

// ---------------------------------------------------------------------------
// The worker
//
// One job at a time. The frame polls two atomics and never waits.
// ---------------------------------------------------------------------------

Job_Kind :: enum u8 {
	None,
	List,
	Extract,
	Create,
}

Job :: struct {
	kind:     Job_Kind,
	// Inputs, owned by the job and freed when it is collected.
	archive:  string,
	dest:     string,
	src:      string,
	out:      string,
	names:    []string,
	overwrite: bool,
	password: string, // never printed, logged or kept past the job

	// Progress, written by the worker and read by the frame.
	total:    int,
	done:     int,
	cancel:   bool,
	running:  bool,
	finished: bool,

	// Results.
	items:    []Item,
	ok:       bool,
	msg:      string,
	errors:   int,
	label:    string,
	fail:     Fail,
	tool:     Tool,
	written:  int,
	kept:     int,
}

job: Job

// CHUNK is how many entries go into one invocation. None of the backends
// reports progress while it works, so the progress bar is real only because
// the work is cut into pieces and counted between them.
CHUNK :: 12

job_busy :: proc() -> bool {
	return sync.atomic_load(&job.running)
}

job_progress :: proc() -> (done, total: int) {
	return sync.atomic_load(&job.done), sync.atomic_load(&job.total)
}

job_cancel :: proc() {
	sync.atomic_store(&job.cancel, true)
}

@(private = "file")
worker :: proc() {
	switch job.kind {
	case .None:
	case .List:
		items, err, fail := list_archive(job.archive, job.password)
		job.items = items
		job.ok = err == ""
		job.msg = err
		job.fail = fail
	case .Extract:
		r := extract_entries(job.archive, job.dest, job.names, job.overwrite, job.password, &job.done, &job.total, &job.cancel)
		job.ok, job.msg, job.fail, job.tool, job.errors = r.ok, r.msg, r.fail, r.tool, r.chunk_errors
		job.written, job.kept = r.written, r.kept
	case .Create:
		sync.atomic_store(&job.total, 1)
		r := create_archive(job.src, job.out, job.password)
		sync.atomic_store(&job.done, 1)
		job.ok, job.msg, job.fail, job.tool = r.ok, r.msg, r.fail, r.tool
	}
	sync.atomic_store(&job.finished, true)
}

Extracted :: struct {
	ok:           bool,
	msg:          string, // heap
	fail:         Fail,
	tool:         Tool,
	written:      int, // files the archive put on disk
	kept:         int, // files already on disk and left alone
	dirs:         int,
	chunk_errors: int,
}

// extract_entries writes the named entries of an archive under dest. It is
// what the window's Extract runs on its worker and what `archive extract`
// runs directly. `names` must already have been through the safety check
// (stage_names); directories among them are made here, and only files are
// handed to the backend, a chunk at a time, so that no tool is ever given a
// directory to recurse into. Progress and cancellation are optional.
extract_entries :: proc(
	archive, dest: string,
	names: []string,
	overwrite: bool,
	password: string,
	done: ^int = nil,
	total: ^int = nil,
	cancel: ^bool = nil,
) -> (r: Extracted) {
	kind := kind_of(archive)
	tool, why := reader_for(kind, password != "", tools())
	r.tool = tool
	if tool == .None {
		r.fail = .Unavailable
		r.msg = strings.clone(why)
		return
	}
	if os.make_directory_all(dest) != nil && !os.is_directory(dest) {
		r.fail = .Failed
		r.msg = fmt.aprintf("could not create %s", dest)
		return
	}

	files := make([dynamic]string, context.temp_allocator)
	for n in names {
		if strings.has_suffix(n, "/") {
			// Already checked: a directory name cannot climb out of dest.
			if os.make_directory_all(fmt.tprintf("%s/%s", dest, n)) == nil {
				r.dirs += 1
			}
			continue
		}
		if os.exists(fmt.tprintf("%s/%s", dest, n)) && !overwrite {
			r.kept += 1
		}
		append(&files, n)
	}
	if total != nil {
		sync.atomic_store(total, len(files))
	}

	i := 0
	for i < len(files) {
		if cancel != nil && sync.atomic_load(cancel) {
			r.fail = .Failed
			r.msg = fmt.aprintf("cancelled after %d of %d files", i, len(files))
			return
		}
		n := min(CHUNK, len(files) - i)
		ran := run_tool(extract_argv(tool, archive, dest, files[i:i + n], overwrite), password)
		if !ran.started || ran.code != 0 {
			// A password problem stops everything: every later chunk would
			// fail the same way, and half an extraction is worse than none.
			f := classify(ran, password != "")
			if f == .Need_Password || f == .Wrong_Password {
				r.fail = f
				r.msg = f == .Need_Password \
					? fmt.aprintf("%s is encrypted — a password is needed", archive) \
					: fmt.aprintf("the password for %s is wrong", archive)
				if i > 0 {
					// What earlier chunks wrote stays; say so.
					r.written = i
				}
				return
			}
			r.chunk_errors += 1
		}
		i += n
		if done != nil {
			sync.atomic_store(done, i)
		}
	}
	r.written = len(files) - (overwrite ? 0 : r.kept)
	r.ok = true
	if r.chunk_errors > 0 {
		r.msg = fmt.aprintf(
			"extracted %d entries to %s (%d chunks reported warnings — existing files are kept)",
			len(names),
			dest,
			r.chunk_errors,
		)
	} else {
		r.msg = fmt.aprintf("extracted %d entries to %s", len(names), dest)
	}
	return
}

Created :: struct {
	ok:        bool,
	msg:       string, // heap
	fail:      Fail,
	tool:      Tool,
	kind:      Kind,
	bytes:     i64,
	encrypted: bool,
}

// create_archive builds `out` from the file or folder `src`, the format named
// by out's extension, encrypted when a password is given. It refuses an `out`
// that exists — the window and the command line alike — and a password for a
// format that has no encryption.
create_archive :: proc(src_in, out_in, password: string) -> (r: Created) {
	src := strings.trim_suffix(strings.trim_space(src_in), "/")
	out := strings.trim_space(out_in)
	r.kind = kind_of(out)
	if !os.exists(src) {
		r.fail = .Failed
		r.msg = fmt.aprintf("%s does not exist", src)
		return
	}
	if os.exists(out) {
		r.fail = .Failed
		r.msg = fmt.aprintf("%s already exists — choose another name", out)
		return
	}
	if password != "" && !can_encrypt(r.kind) {
		r.fail = .Failed
		r.msg = fmt.aprintf("a %s archive has no encryption — use .zip or .7z for a password", KIND_NAMES[r.kind])
		return
	}
	tool, why := writer_for(r.kind, password != "", tools())
	r.tool = tool
	if tool == .None {
		r.fail = .Unavailable
		r.msg = strings.clone(why)
		return
	}
	// The tools run in the source's parent so the archive holds `name/…`
	// rather than the whole absolute path; the output is made absolute first.
	abs_out, aerr := os.get_absolute_path(out, context.temp_allocator)
	if aerr != nil {
		abs_out = out
	}
	abs_src, serr := os.get_absolute_path(src, context.temp_allocator)
	if serr != nil {
		abs_src = src
	}
	parent, base := split_parent(abs_src)
	if parent == "" {
		parent = "."
	}
	ran := run_tool(create_argv(tool, r.kind, abs_out, base, password != ""), password, strings.trim_suffix(parent, "/"))
	if !ran.started || ran.code != 0 || !os.exists(abs_out) {
		r.fail = .Failed
		line := first_error(ran)
		r.msg = line != "" \
			? fmt.aprintf("%s could not create %s: %s", TOOL_NAMES[tool], out, line) \
			: fmt.aprintf("%s could not create %s", TOOL_NAMES[tool], out)
		return
	}
	r.ok = true
	r.encrypted = password != ""
	if st, err := os.stat(abs_out, context.temp_allocator); err == nil {
		r.bytes = i64(st.size)
	}
	r.msg = fmt.aprintf("created %s (%s)%s", out, human(r.bytes), r.encrypted ? ", encrypted" : "")
	return
}

// job_start takes ownership of every string handed to it.
job_start :: proc(j: Job) -> bool {
	if job_busy() {
		return false
	}
	job = j
	job.done = 0
	job.total = 0
	job.errors = 0
	job.ok = false
	job.msg = ""
	job.items = nil
	sync.atomic_store(&job.cancel, false)
	sync.atomic_store(&job.finished, false)
	sync.atomic_store(&job.running, true)
	thread.create_and_start(worker, self_cleanup = true)
	return true
}

// job_collect reports a finished job once and releases its inputs.
job_collect :: proc() -> (j: Job, got: bool) {
	if !sync.atomic_load(&job.running) || !sync.atomic_load(&job.finished) {
		return
	}
	j = job
	got = true
	// The caller takes the items; everything else is this layer's to free.
	job.items = nil
	sync.atomic_store(&job.finished, false)
	sync.atomic_store(&job.running, false)
	return
}

job_release :: proc(j: Job) {
	delete(j.archive)
	delete(j.dest)
	delete(j.src)
	delete(j.out)
	for n in j.names {delete(n)}
	delete(j.names)
	delete(j.msg)
	delete(j.password)
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

human :: proc(n: i64) -> string {
	switch {
	case n < 1024:
		return fmt.tprintf("%d B", n)
	case n < 1024 * 1024:
		return fmt.tprintf("%.1f KB", f64(n) / 1024)
	case n < 1024 * 1024 * 1024:
		return fmt.tprintf("%.1f MB", f64(n) / (1024 * 1024))
	}
	return fmt.tprintf("%.2f GB", f64(n) / (1024 * 1024 * 1024))
}

ARCHIVE_EXTS := [?]string {
	".zip", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz",
	".tar.zst", ".tzst", ".7z", ".rar", ".jar", ".whl", ".cbz", ".gz", ".xz",
	".bz2", ".zst", ".pkg.tar.zst", ".iso", ".deb", ".rpm",
}

is_archive_path :: proc(path: string) -> bool {
	low := strings.to_lower(path, context.temp_allocator)
	for e in ARCHIVE_EXTS {
		if strings.has_suffix(low, e) {
			return true
		}
	}
	return false
}

// archive_label is the format, from the extension, for the header badge.
archive_label :: proc(path: string) -> string {
	low := strings.to_lower(path, context.temp_allocator)
	switch {
	case strings.has_suffix(low, ".zip"), strings.has_suffix(low, ".jar"),
	     strings.has_suffix(low, ".whl"), strings.has_suffix(low, ".cbz"):
		return "ZIP"
	case strings.has_suffix(low, ".tar.gz"), strings.has_suffix(low, ".tgz"):
		return "TAR.GZ"
	case strings.has_suffix(low, ".tar.bz2"), strings.has_suffix(low, ".tbz2"):
		return "TAR.BZ2"
	case strings.has_suffix(low, ".tar.xz"), strings.has_suffix(low, ".txz"):
		return "TAR.XZ"
	case strings.has_suffix(low, ".tar.zst"), strings.has_suffix(low, ".tzst"),
	     strings.has_suffix(low, ".pkg.tar.zst"):
		return "TAR.ZST"
	case strings.has_suffix(low, ".tar"):
		return "TAR"
	case strings.has_suffix(low, ".7z"):
		return "7Z"
	case strings.has_suffix(low, ".rar"):
		return "RAR"
	case strings.has_suffix(low, ".iso"):
		return "ISO"
	case strings.has_suffix(low, ".deb"):
		return "DEB"
	case strings.has_suffix(low, ".rpm"):
		return "RPM"
	}
	return "ARCHIVE"
}

// strip_archive_ext turns `/tmp/sample.tar.gz` into `sample`, which is the
// default destination folder name.
strip_archive_ext :: proc(path: string, al := context.temp_allocator) -> string {
	_, base := split_parent(path)
	low := strings.to_lower(base, context.temp_allocator)
	for e in ARCHIVE_EXTS {
		if strings.has_suffix(low, e) {
			return strings.clone(base[:len(base) - len(e)], al)
		}
	}
	return strings.clone(base, al)
}
