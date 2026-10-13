package palm

// Repositories: where indexes and packages come from, and the checks that
// decide whether to believe them.
//
// A repository line in /etc/palm/repositories (or a --repo) is either an
// absolute path or an http:// URL naming the repository's base. As with apk,
// palm looks for the architecture directory beneath it first:
//
//	<base>/x86_64/PALMINDEX  PALMINDEX.sig  *.palm      (preferred)
//	<base>/PALMINDEX         PALMINDEX.sig  *.palm      (if the above is absent)
//
// so both `--repo distro/out/repo` and `--repo distro/out/repo/x86_64` work.
//
// HTTP indexes are cached under /var/cache/palm/<repo>/ by `palm update` and
// read from there afterwards; packages fetched over HTTP are kept there too
// unless --no-cache. Local repositories are read in place and never copied.
//
// Every index is verified against the trusted keys each time it is loaded --
// from the cache as much as from the network, because a cache is just another
// file someone could have written. A bad or missing signature refuses the
// whole operation unless --allow-untrusted; a package whose sha256 differs
// from its index record is refused, always.

import "core:fmt"
import "core:os"
import "core:strings"

Repo :: struct {
	url:        string, // as configured
	base:       string, // directory or URL holding PALMINDEX and the packages
	http:       bool,
	cache:      string, // http only
	pkgs:       []Pkg,
	signed_by:  string, // the trusted key that verified the index, or ""
	local_file: bool, // a pseudo-repository for `palm add ./foo.palm`
}

repo_urls :: proc(o: ^Opts) -> []string {
	if len(o.repos) > 0 {
		return o.repos[:]
	}
	out := make([dynamic]string)
	data, err := os.read_entire_file_from_path(rooted(o.root, "/etc/palm/repositories", context.temp_allocator), context.temp_allocator)
	if err != nil {
		return out[:]
	}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {
			continue
		}
		append(&out, strings.clone(l))
	}
	return out[:]
}

keys_dir :: proc(o: ^Opts) -> string {
	if o.keys_dir != "" {
		return o.keys_dir
	}
	return rooted(o.root, "/etc/palm/keys")
}

@(private = "file")
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

// open_repos loads and verifies every configured repository. refresh means
// `palm update`: go to the network even when a cached index exists.
open_repos :: proc(o: ^Opts, refresh: bool) -> ([]^Repo, Err) {
	keys := load_trusted(keys_dir(o))
	repos := make([dynamic]^Repo)
	for url in repo_urls(o) {
		r := new(Repo)
		r.url = url
		r.http = strings.has_prefix(url, "http://")
		if !r.http && !strings.has_prefix(url, "/") {
			// A relative --repo is a convenience for the host side.
			abs, aerr := os.get_absolute_path(url, context.allocator)
			if aerr != nil {
				return nil, fail(EXIT_USAGE, "repository %q is neither http:// nor an absolute path", url)
			}
			r.url = abs
		}
		e := load_index(o, r, refresh, keys)
		if e.code == EXIT_UNAVAILABLE {
			// An unreachable mirror is a warning, as in apk; a bad signature
			// is not, and falls through to the refusal below.
			warn("%s", e.msg)
			continue
		}
		if !ok(e) {
			return nil, e
		}
		append(&repos, r)
	}
	return repos[:], Err{}
}

@(private = "file")
load_index :: proc(o: ^Opts, r: ^Repo, refresh: bool, keys: []Trusted_Key) -> Err {
	index, sig: []byte
	if r.http {
		r.cache = rooted(o.root, fmt.tprintf("/var/cache/palm/%s", cache_slug(r.url)))
		cached_index := fmt.tprintf("%s/PALMINDEX", r.cache)
		cached_sig := fmt.tprintf("%s/PALMINDEX.sig", r.cache)
		cached_base := fmt.tprintf("%s/BASE", r.cache)
		if refresh || !os.exists(cached_index) {
			url := strings.trim_right(r.url, "/")
			candidates := [2]string{fmt.tprintf("%s/%s", url, DEFAULT_ARCH), url}
			found := false
			for base in candidates {
				body, status, e := http_get(fmt.tprintf("%s/PALMINDEX", base))
				if !ok(e) {
					return e
				}
				if status == 404 {
					continue
				}
				if status != 200 {
					return fail(EXIT_UNAVAILABLE, "%s/PALMINDEX: HTTP %d", base, status)
				}
				index = body
				r.base = strings.clone(base)
				found = true
				break
			}
			if !found {
				return fail(EXIT_UNAVAILABLE, "%s: no PALMINDEX (tried %s/ and the base)", r.url, DEFAULT_ARCH)
			}
			body, status, e := http_get(fmt.tprintf("%s/PALMINDEX.sig", r.base))
			if !ok(e) {
				return e
			}
			if status == 200 {
				sig = body
			}
			// Cache only after both arrived; verification still happens
			// below, before anything from this index is used.
			_ = os.make_directory_all(r.cache)
			write_file_atomic(cached_index, index)
			write_file_atomic(cached_sig, sig)
			write_file_atomic(cached_base, transmute([]byte)r.base)
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
		arch_dir := fmt.tprintf("%s/%s", strings.trim_right(r.url, "/"), DEFAULT_ARCH)
		r.base = os.exists(fmt.tprintf("%s/PALMINDEX", arch_dir)) ? strings.clone(arch_dir) : strings.clone(strings.trim_right(r.url, "/"))
		err: os.Error
		index, err = os.read_entire_file_from_path(fmt.tprintf("%s/PALMINDEX", r.base), context.allocator)
		if err != nil {
			return fail(EXIT_UNAVAILABLE, "%s: no PALMINDEX", r.base)
		}
		sig, _ = os.read_entire_file_from_path(fmt.tprintf("%s/PALMINDEX.sig", r.base), context.allocator)
	}

	r.signed_by = verify_any(keys, index, string(sig))
	if r.signed_by == "" {
		why := len(sig) == 0 ? "is not signed" : "has a signature no trusted key verifies"
		if !o.allow_untrusted {
			return fail(EXIT_REFUSED, "%s: the index %s (keys: %s); refusing. --allow-untrusted overrides", r.url, why, keys_dir(o))
		}
		warn("%s: the index %s; continuing because of --allow-untrusted", r.url, why)
	}
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
	p, e := read_pkginfo(data)
	if !ok(e) {
		return nil, fail(e.code, "%s: %s", path, e.msg)
	}
	abs, _ := os.get_absolute_path(path, context.allocator)
	r := new(Repo)
	r.url = abs
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

// fetch_package returns the bytes of a .palm, verified against the sha256 its
// index gave. This is the second link of the chain of trust, and it is not
// optional: --allow-untrusted relaxes the index signature, never this.
fetch_package :: proc(o: ^Opts, p: ^Pkg) -> ([]byte, Err) {
	r := p.repo
	if r == nil {
		return nil, fail(EXIT_NOT_FOUND, "%s is not available from any repository", pkg_id(p))
	}
	data: []byte
	if r.http {
		cached := fmt.tprintf("%s/%s", r.cache, p.filename)
		if d, err := os.read_entire_file_from_path(cached, context.allocator); err == nil {
			if sha256_hex(d, context.temp_allocator) == p.sha256 {
				return d, Err{}
			}
			delete(d)
		}
		body, status, e := http_get(fmt.tprintf("%s/%s", r.base, p.filename))
		if !ok(e) {
			return nil, e
		}
		if status != 200 {
			return nil, fail(EXIT_UNAVAILABLE, "%s/%s: HTTP %d", r.base, p.filename, status)
		}
		data = body
	} else {
		err: os.Error
		data, err = os.read_entire_file_from_path(fmt.tprintf("%s/%s", r.base, p.filename), context.allocator)
		if err != nil {
			return nil, fail(EXIT_NOT_FOUND, "%s/%s is missing", r.base, p.filename)
		}
	}
	got := sha256_hex(data, context.temp_allocator)
	if got != p.sha256 {
		return nil, fail(
			EXIT_REFUSED,
			"%s: sha256 mismatch -- the file does not match the signed index (want %s, got %s); refusing",
			p.filename,
			p.sha256,
			got,
		)
	}
	if r.http && !o.no_cache {
		_ = os.make_directory_all(r.cache)
		write_file_atomic(fmt.tprintf("%s/%s", r.cache, p.filename), data)
	}
	return data, Err{}
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
