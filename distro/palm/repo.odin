package palm

// Repositories: where indexes and packages come from, and the checks that
// decide whether to believe them.
//
// A line in /etc/palm/repositories (or a --repo) is one repository. It names
// the repository's base as an absolute path or an http:// or https:// URL,
// and may name more URLs after it, separated by spaces: mirrors of the same
// repository, tried in order.
//
//	https://repo.example.org/palmframe https://mirror.example.net/palmframe
//
// As with apk, palm looks for the architecture directory beneath a base
// first:
//
//	<base>/x86_64/PALMINDEX  PALMINDEX.sig  *.palm      (preferred)
//	<base>/PALMINDEX         PALMINDEX.sig  *.palm      (if the above is absent)
//
// so both `--repo distro/out/repo` and `--repo distro/out/repo/x86_64` work.
//
// Remote indexes are cached under /var/cache/palm/<repo>/ by `palm update`
// and read from there afterwards; packages fetched over the network are kept
// there too unless --no-cache. Local repositories are read in place.
//
// Every index is verified against the trusted keys each time it is loaded --
// from the cache as much as from the network, because a cache is just another
// file someone could have written. A bad or missing signature refuses the
// whole operation unless --allow-untrusted; a package whose sha256 differs
// from its index record is refused, always.
//
// FRESHNESS. A signature says who wrote an index, not when, so a mirror (or
// anyone between palm and a plain-http mirror) could serve an old, validly
// signed index to keep a machine from seeing a security fix. Indexes carry
// the time they were made (`# generated = <unix seconds>`, inside the signed
// bytes), and `palm update` refuses an index older than the one it already
// verified for that repository, moving on to the next mirror. `palm update`
// prints each index's date so a stale repository is visible.
//
// Which mirror served the index is remembered; packages are fetched from it
// first and from the other mirrors if it fails. Any mirror will do for a
// package, since the signed index already fixed its sha256.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Repo :: struct {
	url:        string, // the first URL or path of the line: its name and cache key
	mirrors:    []string, // every URL of the line, in order
	base:       string, // directory or URL holding PALMINDEX and the packages
	remote:     bool,
	cache:      string, // remote only
	pkgs:       []Pkg,
	signed_by:  string, // the trusted key that verified the index, or ""
	generated:  i64, // unix seconds from the index, 0 if it has none
	local_file: bool, // a pseudo-repository for `palm add ./foo.palm`
}

// How far open_repos may go for an index.
Repo_Mode :: enum {
	Offline, // never touch the network: cached and local indexes only
	Cached, // the cached index if there is one, else fetch it
	Refresh, // fetch every remote index (`palm update`)
}

// repo_lines returns the configured repositories, one slice of mirrors each.
repo_lines :: proc(o: ^Opts) -> [][]string {
	out := make([dynamic][]string)
	if len(o.repos) > 0 {
		for r in o.repos {
			append(&out, strings.fields(r))
		}
		return out[:]
	}
	data, err := os.read_entire_file_from_path(rooted(o.root, "/etc/palm/repositories", context.temp_allocator), context.temp_allocator)
	if err != nil {
		return out[:]
	}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {
			continue
		}
		fields := strings.fields(l)
		for &f in fields {f = strings.clone(f)}
		append(&out, fields)
	}
	return out[:]
}

keys_dir :: proc(o: ^Opts) -> string {
	if o.keys_dir != "" {
		return o.keys_dir
	}
	return rooted(o.root, "/etc/palm/keys")
}

cache_slug :: proc(url: string) -> string {
	b := make([]byte, len(url))
	for c, i in transmute([]byte)url {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '-':
			b[i] = c
		case:
			b[i] = '_'
		}
	}
	return string(b)
}

// index_generated reads `# generated = <unix seconds>` from an index's
// header comment; 0 if there is none (an index from palm 0.1).
index_generated :: proc(text: string) -> i64 {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" {
			continue
		}
		if !strings.has_prefix(l, "#") {
			break
		}
		body := strings.trim_space(l[1:])
		if strings.has_prefix(body, "generated") {
			if eq := strings.index_byte(body, '='); eq > 0 {
				v, _ := strconv.parse_i64(strings.trim_space(body[eq + 1:]))
				return v
			}
		}
	}
	return 0
}

format_date :: proc(unix: i64) -> string {
	if unix <= 0 {
		return "undated"
	}
	t := time.unix(unix, 0)
	y, mon, d := time.date(t)
	h, mi, _ := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d UTC", y, int(mon), d, h, mi)
}

// open_repos loads and verifies every configured repository. A repository
// that cannot be reached is a warning (as in apk) and is left out; a bad
// signature is not, and refuses the whole operation. `skipped` says why each
// repository left out was left out (empty for one a query simply has no
// cached index for).
open_repos :: proc(o: ^Opts, mode: Repo_Mode) -> (repos: []^Repo, skipped: []string, e: Err) {
	why := make([dynamic]string)
	keys := load_trusted(keys_dir(o))
	out := make([dynamic]^Repo)
	for line in repo_lines(o) {
		if len(line) == 0 {continue}
		r := new(Repo)
		r.url = line[0]
		r.remote = is_remote_url(line[0])
		mirrors := make([dynamic]string)
		for m in line {
			if is_remote_url(m) != r.remote {
				return nil, nil, fail(EXIT_USAGE, "repository line %q mixes local paths and URLs", strings.join(line, " ", context.temp_allocator))
			}
			if !r.remote && !strings.has_prefix(m, "/") {
				// A relative --repo is a convenience for the host side.
				abs, aerr := os.get_absolute_path(m, context.allocator)
				if aerr != nil {
					return nil, nil, fail(EXIT_USAGE, "repository %q is neither a URL nor an absolute path", m)
				}
				append(&mirrors, abs)
			} else {
				append(&mirrors, m)
			}
		}
		r.mirrors = mirrors[:]
		r.url = mirrors[0]
		le := load_index(o, r, mode, keys)
		if le.code == EXIT_UNAVAILABLE {
			if le.msg != "" {warn("%s", le.msg)}
			append(&why, le.msg)
			continue
		}
		if !ok(le) {
			return nil, nil, le
		}
		append(&out, r)
	}
	return out[:], why[:], Err{}
}

@(private = "file")
Fetched_Index :: struct {
	index, sig: []byte,
	base:       string,
	signed_by:  string,
	generated:  i64,
}

@(private = "file")
verify_index :: proc(o: ^Opts, r: ^Repo, index, sig: []byte, keys: []Trusted_Key, from: string) -> (string, Err) {
	signer := verify_any(keys, index, string(sig))
	if signer == "" {
		why := len(sig) == 0 ? "is not signed" : "has a signature no trusted key verifies"
		if !o.allow_untrusted {
			return "", fail(EXIT_REFUSED, "%s: the index %s (keys: %s); refusing. --allow-untrusted overrides", from, why, keys_dir(o))
		}
		warn("%s: the index %s; continuing because of --allow-untrusted", from, why)
	}
	return signer, Err{}
}

// fetch_index tries one mirror: <m>/x86_64/ first, then <m>/ itself.
@(private = "file")
fetch_index :: proc(o: ^Opts, r: ^Repo, mirror: string, keys: []Trusted_Key) -> (f: Fetched_Index, e: Err) {
	url := strings.trim_right(mirror, "/")
	candidates := [2]string{fmt.tprintf("%s/%s", url, DEFAULT_ARCH), url}
	for base in candidates {
		body, status, ge := http_get(fmt.tprintf("%s/PALMINDEX", base))
		if !ok(ge) {
			return f, ge
		}
		if status == 404 || status == 403 {
			continue
		}
		if status != 200 {
			return f, fail(EXIT_UNAVAILABLE, "%s/PALMINDEX: HTTP %d", base, status)
		}
		f.index = body
		f.base = strings.clone(base)
		break
	}
	if f.base == "" {
		return f, fail(EXIT_UNAVAILABLE, "%s: no PALMINDEX (tried %s/ and the base)", mirror, DEFAULT_ARCH)
	}
	body, status, ge := http_get(fmt.tprintf("%s/PALMINDEX.sig", f.base))
	if !ok(ge) {
		return f, ge
	}
	if status == 200 {
		f.sig = body
	}
	f.signed_by, e = verify_index(o, r, f.index, f.sig, keys, mirror)
	f.generated = index_generated(string(f.index))
	return
}

@(private = "file")
load_index :: proc(o: ^Opts, r: ^Repo, mode: Repo_Mode, keys: []Trusted_Key) -> Err {
	index, sig: []byte
	if r.remote {
		r.cache = rooted(o.root, fmt.tprintf("/var/cache/palm/%s", cache_slug(r.url)))
		cached_index := fmt.tprintf("%s/PALMINDEX", r.cache)
		cached_sig := fmt.tprintf("%s/PALMINDEX.sig", r.cache)
		cached_base := fmt.tprintf("%s/BASE", r.cache)
		have_cache := os.exists(cached_index)
		if mode == .Offline && !have_cache {
			// Not an error and not worth a warning: a query simply does not
			// know this repository's packages until `palm update`.
			return Err{EXIT_UNAVAILABLE, ""}
		}
		if mode == .Refresh || !have_cache {
			// What is already verified sets the floor for freshness.
			floor: i64 = 0
			if have_cache {
				old, _ := os.read_entire_file_from_path(cached_index, context.temp_allocator)
				old_sig, _ := os.read_entire_file_from_path(cached_sig, context.temp_allocator)
				if verify_any(keys, old, string(old_sig)) != "" {
					floor = index_generated(string(old))
				}
			}
			got: Fetched_Index
			found := false
			problems := make([dynamic]string, context.temp_allocator)
			refused := false
			for m in r.mirrors {
				f, fe := fetch_index(o, r, m, keys)
				if !ok(fe) {
					append(&problems, fe.msg)
					refused ||= fe.code == EXIT_REFUSED
					continue
				}
				if f.generated < floor {
					append(&problems, fmt.tprintf("%s serves an index from %s, older than the %s one already verified; a stale mirror or a replay, refused", m, format_date(f.generated), format_date(floor)))
					refused = true
					continue
				}
				got = f
				found = true
				break
			}
			if !found {
				msg := strings.join(problems[:], "; ", context.temp_allocator)
				if refused {
					return fail(EXIT_REFUSED, "%s", msg)
				}
				return fail(EXIT_UNAVAILABLE, "%s", msg)
			}
			if len(problems) > 0 {
				warn("%s", strings.join(problems[:], "; ", context.temp_allocator))
			}
			// Verified above; the cache holds only what passed.
			_ = os.make_directory_all(r.cache)
			write_file_atomic(cached_index, got.index)
			write_file_atomic(cached_sig, got.sig)
			write_file_atomic(cached_base, transmute([]byte)got.base)
			index, sig, r.base = got.index, got.sig, got.base
		} else {
			err: os.Error
			index, err = os.read_entire_file_from_path(cached_index, context.allocator)
			if err != nil {
				return fail(EXIT_UNAVAILABLE, "cannot read cached index %s", cached_index)
			}
			sig, _ = os.read_entire_file_from_path(cached_sig, context.allocator)
			b, _ := os.read_entire_file_from_path(cached_base, context.allocator)
			r.base = len(b) > 0 ? string(b) : strings.trim_right(r.url, "/")
		}
	} else {
		for m in r.mirrors {
			arch_dir := fmt.tprintf("%s/%s", strings.trim_right(m, "/"), DEFAULT_ARCH)
			base := os.exists(fmt.tprintf("%s/PALMINDEX", arch_dir)) ? arch_dir : strings.trim_right(m, "/")
			data, err := os.read_entire_file_from_path(fmt.tprintf("%s/PALMINDEX", base), context.allocator)
			if err == nil {
				index = data
				r.base = strings.clone(base)
				sig, _ = os.read_entire_file_from_path(fmt.tprintf("%s/PALMINDEX.sig", base), context.allocator)
				break
			}
		}
		if index == nil {
			return fail(EXIT_UNAVAILABLE, "%s: no PALMINDEX", r.url)
		}
	}

	signer, ve := verify_index(o, r, index, sig, keys, r.url)
	if !ok(ve) {
		return ve
	}
	r.signed_by = signer
	r.generated = index_generated(string(index))
	pkgs, e := index_parse(string(index))
	if !ok(e) {
		return fail(e.code, "%s: %s", r.url, e.msg)
	}
	for &p in pkgs {
		p.repo = r
	}
	r.pkgs = pkgs
	return Err{}
}

// local_file_repo wraps `palm add ./foo-1.0-r0.palm`. There is no index to
// vouch for such a file, so it needs --allow-untrusted; its sha256 is taken
// from the file itself and only guards against it changing mid-transaction.
local_file_repo :: proc(o: ^Opts, path: string) -> (^Repo, Err) {
	if !o.allow_untrusted {
		return nil, fail(EXIT_REFUSED, "%s is a local package file with no signed index behind it; refusing. --allow-untrusted overrides", path)
	}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return nil, fail(EXIT_NOT_FOUND, "cannot read %s", path)
	}
	defer delete(data)
	p, e := read_pkginfo(data)
	if !ok(e) {
		return nil, fail(e.code, "%s: %s", path, e.msg)
	}
	abs, _ := os.get_absolute_path(path, context.allocator)
	r := new(Repo)
	r.url = abs
	r.mirrors = {abs}
	r.base = parent_dir(abs)
	r.local_file = true
	p.sha256 = sha256_hex(data)
	p.csize = i64(len(data))
	p.filename = strings.clone(base_name(abs))
	p.repo = r
	pkgs := make([]Pkg, 1)
	pkgs[0] = p
	r.pkgs = pkgs
	return r, Err{}
}

// ---------------------------------------------------------------------------
// Fetching packages
// ---------------------------------------------------------------------------

// A package on disk, verified against its index's sha256. `temp` means palm
// downloaded it only for this transaction (--no-cache, or a cache it cannot
// write) and removes it afterwards.
Fetched :: struct {
	path: string,
	temp: bool,
}

// cached_package_path is where a remote package lives once fetched.
@(private = "file")
cached_package_path :: proc(r: ^Repo, p: ^Pkg) -> string {
	return fmt.aprintf("%s/%s", r.cache, p.filename)
}

// package_is_local: a package that needs no network to read -- in a local
// repository, or already in the cache with the right sha256.
package_is_local :: proc(p: ^Pkg) -> bool {
	r := p.repo
	if r == nil {return false}
	if !r.remote {return true}
	sum, okh := sha256_file_hex(cached_package_path(r, p), context.temp_allocator)
	return okh && sum == p.sha256
}

// fetch_package puts one verified .palm on disk and returns where. This is
// the second link of the chain of trust and it is not optional:
// --allow-untrusted relaxes the index signature, never this.
fetch_package :: proc(o: ^Opts, p: ^Pkg) -> (Fetched, Err) {
	r := p.repo
	if r == nil {
		return {}, fail(EXIT_NOT_FOUND, "%s is not available from any repository", pkg_id(p))
	}
	if !r.remote {
		path := r.local_file ? r.url : fmt.aprintf("%s/%s", r.base, p.filename)
		sum, okh := sha256_file_hex(path, context.temp_allocator)
		if !okh {
			return {}, fail(EXIT_NOT_FOUND, "%s is missing", path)
		}
		if sum != p.sha256 {
			return {}, sha_refusal(p, sum)
		}
		return Fetched{path, false}, Err{}
	}
	cached := cached_package_path(r, p)
	if sum, okh := sha256_file_hex(cached, context.temp_allocator); okh && sum == p.sha256 {
		return Fetched{cached, false}, Err{}
	}
	// Where to put it: the cache, if palm may write there (root, or the
	// --root owner); otherwise a private temporary directory.
	dir := r.cache
	temp := o.no_cache
	if !mkdir_p(dir) || !dir_writable(dir) {
		dir = temp_download_dir()
		temp = true
	}
	dest := fmt.aprintf("%s/%s", dir, p.filename)
	// The mirror that served the index first, then the others.
	bases := make([dynamic]string, context.temp_allocator)
	append(&bases, r.base)
	for m in r.mirrors {
		mb := strings.trim_right(m, "/")
		for cand in ([2]string{fmt.tprintf("%s/%s", mb, DEFAULT_ARCH), mb}) {
			if cand != r.base {append(&bases, cand)}
		}
	}
	last: Err
	for b in bases {
		e := http_download(fmt.tprintf("%s/%s", b, p.filename), dest, p.sha256, p.csize)
		if ok(e) {
			return Fetched{dest, temp}, Err{}
		}
		last = e
		if e.code == EXIT_REFUSED && b == r.base {
			// A mismatch from the mirror that signed off on the index is
			// worth reporting even if another mirror has the right bytes.
			warn("%s", e.msg)
		}
	}
	if strings.contains(last.msg, "HTTP 404") {
		return {}, fail(EXIT_UNAVAILABLE, "%s: no mirror has it (%s); the cached index may be out of date, run palm update", p.filename, last.msg)
	}
	return {}, last
}

@(private = "file")
sha_refusal :: proc(p: ^Pkg, got: string) -> Err {
	return fail(EXIT_REFUSED, "%s: sha256 mismatch -- the file does not match the signed index (want %s, got %s); refusing", p.filename, p.sha256, got)
}

@(private = "file")
dir_writable :: proc(dir: string) -> bool {
	probe := fmt.tprintf("%s/.palm-probe.%d", dir, os.get_pid())
	f, err := os.open(probe, {.Write, .Create, .Trunc}, os.perm_number(0o600))
	if err != nil {
		return false
	}
	os.close(f)
	_ = os.remove(probe)
	return true
}

@(private = "file")
g_temp_dir: string
@(private = "file")
g_temp_mutex: sync.Mutex

@(private = "file")
temp_download_dir :: proc() -> string {
	sync.mutex_lock(&g_temp_mutex)
	defer sync.mutex_unlock(&g_temp_mutex)
	if g_temp_dir == "" {
		base := "/tmp"
		if v, found := os.lookup_env("TMPDIR", context.temp_allocator); found && v != "" {
			base = v
		}
		g_temp_dir = fmt.aprintf("%s/palm-%d", base, os.get_pid())
		_ = os.make_directory_all(g_temp_dir, os.perm_number(0o700))
	}
	return g_temp_dir
}

// remove_temp_downloads deletes what fetch_package put in a temporary place.
remove_temp_downloads :: proc(fetched: []Fetched) {
	for f in fetched {
		if f.temp && f.path != "" {
			_ = os.remove(f.path)
		}
	}
	if g_temp_dir != "" {
		_ = os.remove(g_temp_dir) // only if empty
	}
}

// FETCH_WORKERS is how many packages download at once. Four connections is
// what a CDN treats as one polite client, and enough to hide the latency of
// many small packages behind one large one.
FETCH_WORKERS :: 4

@(private = "file")
Fetch_Job :: struct {
	o:        ^Opts,
	pkgs:     []^Pkg,
	out:      []Fetched,
	errs:     []Err,
	next:     int, // atomic
	done:     int, // under mutex
	steps:    int,
	mutex:    sync.Mutex,
	stop:     bool, // atomic: a failure stops new downloads
	threaded: bool,
}

@(private = "file")
fetch_worker :: proc(j: ^Fetch_Job) {
	defer http_close_all()
	for {
		if sync.atomic_load(&j.stop) {return}
		i := sync.atomic_add(&j.next, 1)
		if i >= len(j.pkgs) {return}
		p := j.pkgs[i]
		f, e := fetch_package(j.o, p)
		sync.mutex_lock(&j.mutex)
		j.out[i] = f
		j.errs[i] = e
		j.done += 1
		if ok(e) {
			progress("fetch", p.name, p.version, j.done, j.steps)
		} else {
			sync.atomic_store(&j.stop, true)
		}
		sync.mutex_unlock(&j.mutex)
		if j.threaded {
			// a worker's own arena; never the caller's, which holds j.pkgs
			free_all(context.temp_allocator)
		}
	}
}

// fetch_packages fetches every package, the remote ones FETCH_WORKERS at a
// time, and returns them in the order given. On a failure the first error
// (in that order) is returned and nothing more is started.
fetch_packages :: proc(o: ^Opts, pkgs: []^Pkg, steps: int) -> ([]Fetched, Err) {
	j := new(Fetch_Job)
	defer free(j)
	j.o = o
	j.pkgs = pkgs
	j.out = make([]Fetched, len(pkgs))
	j.errs = make([]Err, len(pkgs))
	j.steps = steps
	remote := 0
	for p in pkgs {
		if !package_is_local(p) {remote += 1}
	}
	tls_roots() // load the CA bundle once, before the workers race for it
	workers := min(FETCH_WORKERS, remote)
	if workers <= 1 {
		fetch_worker(j)
	} else {
		j.threaded = true
		threads := make([]^thread.Thread, workers, context.temp_allocator)
		for &t in threads {
			// No init_context: each worker gets a fresh context with its own
			// temporary allocator, which the main thread's must not be shared as.
			t = thread.create_and_start_with_poly_data(j, fetch_worker)
		}
		for t in threads {
			thread.join(t)
			thread.destroy(t)
		}
	}
	for e, i in j.errs {
		if !ok(e) {
			remove_temp_downloads(j.out)
			return nil, e
		}
		if j.out[i].path == "" {
			remove_temp_downloads(j.out)
			return nil, fail(EXIT_FAILED, "%s was not fetched", pkg_id(pkgs[i]))
		}
	}
	return j.out, Err{}
}

// read_pkginfo opens a .palm far enough to read what it says it is.
read_pkginfo :: proc(data: []byte) -> (Pkg, Err) {
	raw, okz := gzip_decompress(data, context.allocator)
	if !okz {
		return {}, fail(EXIT_FAILED, "not a gzip stream")
	}
	defer delete(raw)
	entries, e := tar_read(raw, context.temp_allocator)
	if !ok(e) {
		return {}, e
	}
	if len(entries) == 0 || entries[0].path != ".PKGINFO" {
		return {}, fail(EXIT_FAILED, "the first member is not .PKGINFO")
	}
	recs := parse_records(string(entries[0].data), context.temp_allocator)
	if len(recs) != 1 {
		return {}, fail(EXIT_FAILED, ".PKGINFO is malformed")
	}
	return pkg_from_record(recs[0])
}
