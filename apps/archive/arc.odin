package main

// Reading archives, checking them, and the worker that does anything slow.
//
// Listing goes through two bsdtar runs rather than one: `-tf` gives the exact
// names, one per line, and `-tvf` gives the metadata. Parsing names out of the
// verbose listing alone is a trap — `project/docs/release notes.md` has a space
// in it, and so does half of everything a person ever zipped.
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

// list_archive reads an archive into Items. It runs on the worker thread.
list_archive :: proc(path: string) -> (items: []Item, err: string) {
	names, ok1 := kit.run_lines({"bsdtar", "-tf", path}, context.allocator)
	if !ok1 {
		return nil, fmt.aprintf("bsdtar could not read %s", path)
	}
	verbose, _ := kit.run_lines({"bsdtar", "-tvf", path}, context.allocator)
	defer {
		for v in verbose {delete(v)}
		delete(verbose)
	}

	out := make([dynamic]Item)
	for n, i in names {
		it := Item {
			name = n,
			dir  = strings.has_suffix(n, "/"),
		}
		if i < len(verbose) {
			if perms, size, date, good := parse_verbose(verbose[i]); good {
				it.perms = strings.clone(perms)
				it.size = size
				it.date = strings.clone(date)
				it.dir = len(perms) > 0 && perms[0] == 'd'
				it.link = len(perms) > 0 && perms[0] == 'l'
			}
		}
		it.parent, it.base = split_parent(n)
		it.parent = strings.clone(it.parent)
		it.base = strings.clone(it.base)
		it.why = strings.clone(check_name(n, it.link))
		it.bad = it.why != ""
		append(&out, it)
	}
	return out[:], ""
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
}

job: Job

// CHUNK is how many entries go into one bsdtar invocation. bsdtar reports
// nothing while it works, so the progress bar is real only because the work is
// cut into pieces and counted between them.
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
		items, err := list_archive(job.archive)
		job.items = items
		job.ok = err == ""
		job.msg = err
	case .Extract:
		run_extract()
	case .Create:
		run_create()
	}
	sync.atomic_store(&job.finished, true)
}

@(private = "file")
run_extract :: proc() {
	if os.make_directory_all(job.dest) != nil && !os.exists(job.dest) {
		job.ok = false
		job.msg = fmt.aprintf("could not create %s", job.dest)
		return
	}
	sync.atomic_store(&job.total, len(job.names))

	i := 0
	for i < len(job.names) {
		if sync.atomic_load(&job.cancel) {
			job.ok = false
			job.msg = fmt.aprintf("cancelled after %d of %d entries", i, len(job.names))
			return
		}
		n := min(CHUNK, len(job.names) - i)

		argv := make([dynamic]string, context.temp_allocator)
		append(&argv, "bsdtar", "-x", "-f", job.archive, "-C", job.dest, "--no-same-owner")
		if !job.overwrite {
			// -k keeps whatever is already on disk. Overwriting is only ever
			// done when the user picked it in the dialog.
			append(&argv, "-k")
		}
		append(&argv, "--")
		for k in 0 ..< n {
			append(&argv, job.names[i + k])
		}

		if _, ok := kit.run(argv[:], context.temp_allocator); !ok {
			job.errors += 1
		}
		i += n
		sync.atomic_store(&job.done, i)
		free_all(context.temp_allocator)
	}

	job.ok = true
	if job.errors > 0 {
		job.msg = fmt.aprintf(
			"extracted %d entries to %s (%d chunks reported warnings — existing files are kept)",
			len(job.names),
			job.dest,
			job.errors,
		)
	} else {
		job.msg = fmt.aprintf("extracted %d entries to %s", len(job.names), job.dest)
	}
}

@(private = "file")
run_create :: proc() {
	sync.atomic_store(&job.total, 1)
	parent, base := split_parent(strings.trim_suffix(job.src, "/"))
	if parent == "" {
		parent = "."
	}
	// bsdtar -a picks the format from the output file's extension, so
	// `out.zip` really is a zip and `out.tar.gz` really is gzipped tar.
	_, ok := kit.run(
		{"bsdtar", "-a", "-c", "-f", job.out, "-C", strings.trim_suffix(parent, "/"), base},
		context.temp_allocator,
	)
	sync.atomic_store(&job.done, 1)
	job.ok = ok
	if ok {
		size := i64(0)
		if st, serr := os.stat(job.out, context.temp_allocator); serr == nil {
			size = i64(st.size)
		}
		job.msg = fmt.aprintf("created %s (%s)", job.out, human(size))
	} else {
		job.msg = fmt.aprintf("bsdtar could not create %s", job.out)
	}
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
