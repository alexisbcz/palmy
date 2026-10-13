package palm

// `palm --selftest` -- runs on the build host, as an ordinary user, and
// touches nothing outside a scratch directory it removes afterwards.
//
// It proves the pieces from the bottom up, and then the whole thing the way
// a person would use it:
//
//   * the formats palm writes itself: ustar round trips (long paths, long
//     link targets, setuid modes, named owners) and an archive written by the
//     host's GNU tar; DEFLATE/gzip round trips through Odin's decoder AND the
//     system's `gzip -d`, because an encoder is only correct relative to the
//     decoders that will read it,
//   * the cryptography it relies on: sha256 and ed25519 against published
//     vectors (RFC 8032 test 1), then palm's own keygen, sign and verify,
//   * apk version ordering and constraints, and the resolver: install order,
//     provides, the conflict-repair restart, and unsatisfiable requests,
//   * the HTTP response parser on chunked, sized and truncated bodies,
//   * then by argv, through dispatch, exactly as typed at a shell:
//     build -> index -> add -> verify -> fix -> upgrade -> del in a temporary
//     --root; file-conflict refusal; /etc config protection; a tampered
//     package and a tampered index each refused with nothing changed; an
//     untrusted key refused; a repository served over real HTTP by
//     `python3 -m http.server` on localhost; and the passthrough to the
//     command surface, by running this very binary with a fake surface.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:time"

@(private = "file")
checks := 0
@(private = "file")
failures := 0

@(private = "file")
check :: proc(okk: bool, what: string, args: ..any) {
	checks += 1
	if !okk {
		failures += 1
		fmt.printf("  FAIL  %s\n", fmt.tprintf(what, ..args))
	}
}

@(private = "file")
eq_s :: proc(got, want: string, what: string, args: ..any) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s: got %q, want %q\n", fmt.tprintf(what, ..args), got, want)
	}
}

@(private = "file")
eq_i :: proc(got, want: int, what: string, args: ..any) {
	checks += 1
	if got != want {
		failures += 1
		fmt.printf("  FAIL  %s: got %d, want %d\n", fmt.tprintf(what, ..args), got, want)
	}
}

@(private = "file")
section :: proc(name: string) {
	fmt.printf("\n%s\n", name)
}

@(private = "file")
g_dir: string

@(private = "file")
scratch :: proc(rel: string) -> string {
	if g_dir == "" {
		g_dir = fmt.aprintf("/tmp/palm-selftest-%d", os.get_pid())
		_ = os.remove_all(g_dir)
		mkdir_p(g_dir)
	}
	return fmt.aprintf("%s/%s", g_dir, rel)
}

@(private = "file")
put :: proc(path, text: string, mode := 0o644) {
	mkdir_p(parent_dir(path))
	if os.write_entire_file(path, transmute([]byte)text, os.perm_number(mode)) != nil {
		failures += 1
		fmt.printf("  FAIL  could not write the fixture %s\n", path)
	}
}

@(private = "file")
slurp :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return ""
	}
	return string(data)
}

// run drives palm by argv with its stdout and stderr sent to a file, and
// returns the exit code. g_out holds what it printed.
@(private = "file")
g_out: string

@(private = "file")
run :: proc(args: ..string) -> int {
	cap_path := scratch("captured")
	fd, errno := linux.open(strings.clone_to_cstring(cap_path, context.temp_allocator), {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR})
	if errno != .NONE {
		return dispatch(args)
	}
	saved_out, _ := linux.dup(1)
	saved_err, _ := linux.dup(2)
	linux.dup2(fd, 1)
	linux.dup2(fd, 2)
	code := dispatch(args)
	linux.dup2(saved_out, 1)
	linux.dup2(saved_err, 2)
	linux.close(saved_out)
	linux.close(saved_err)
	linux.close(fd)
	g_out = slurp(cap_path)
	return code
}

@(private = "file")
replace :: proc(s, old, new: string) -> string {
	out, _ := strings.replace_all(s, old, new)
	return out
}

@(private = "file")
exec :: proc(cmd: ..string) -> (int, string) {
	state, out, errb, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil {
		return -1, fmt.tprintf("%v", err)
	}
	return state.exit_code, strings.concatenate({string(out), string(errb)})
}

selftest :: proc() {
	t0 := time.now()
	fmt.println("palm self-test")
	g_quiet = true

	test_tar()
	test_gzip()
	test_crypto()
	test_versions()
	test_resolver()
	test_http_parser()
	test_recipes()
	test_lifecycle()
	test_tampering()
	test_http_repo()
	test_passthrough()

	if g_dir != "" {
		_ = os.remove_all(g_dir)
	}
	ms := time.duration_milliseconds(time.since(t0))
	fmt.printf("\n%d assertions, %d failures, %.0f ms\n", checks, failures, ms)
	if failures > 0 {
		os.exit(1)
	}
}

// ---------------------------------------------------------------------------
// tar
// ---------------------------------------------------------------------------

test_tar :: proc() {
	section("tar")
	long_dir := strings.repeat("d", 120, context.temp_allocator)
	very_long := fmt.tprintf("/%s/%s/%s", long_dir, long_dir, strings.repeat("f", 90, context.temp_allocator))
	long_target := strings.repeat("t/", 70, context.temp_allocator)
	in_entries := [?]Tar_Entry {
		{path = ".PKGINFO", type = .File, mode = 0o644, data = transmute([]byte)string("pkgname = x\n")},
		{path = "/usr", type = .Dir, mode = 0o755},
		{path = "/usr/bin/su", type = .File, mode = 0o4755, data = transmute([]byte)string("#!/bin/sh\n")},
		{path = "/home/palm", type = .Dir, mode = 0o700, uid = 1000, gid = 1000, uname = "palm", gname = "palm"},
		{path = "/bin", type = .Symlink, mode = 0o777, link = "usr/bin"},
		{path = fmt.tprintf("/%s/%s", long_dir, "medium"), type = .File, mode = 0o600, data = transmute([]byte)string("prefix field")},
		{path = very_long, type = .File, mode = 0o644, data = transmute([]byte)string("pax path")},
		{path = "/lnk", type = .Symlink, mode = 0o777, link = long_target},
		{path = "/usr/bin/su2", type = .Hardlink, mode = 0o4755, link = "/usr/bin/su"},
		{path = "/empty", type = .File, mode = 0o644},
	}
	buf := make([dynamic]byte)
	for e in in_entries {
		tar_write(&buf, e)
	}
	tar_finish(&buf)
	check(len(buf) % 512 == 0, "archive is a whole number of blocks")
	out, e := tar_read(buf[:])
	check(ok(e), "own archive reads back: %s", e.msg)
	eq_i(len(out), len(in_entries), "entry count")
	for i in 0 ..< min(len(out), len(in_entries)) {
		a, b := in_entries[i], out[i]
		eq_s(b.path, a.path, "path %d", i)
		check(a.type == b.type, "type of %s", a.path)
		eq_i(int(b.mode), int(a.mode), "mode of %s", a.path)
		eq_i(b.uid, a.uid, "uid of %s", a.path)
		eq_s(b.uname, a.uname != "" ? a.uname : "root", "uname of %s", a.path)
		eq_s(b.link, a.link, "link of %s", a.path)
		eq_s(string(b.data), string(a.data), "data of %s", a.path)
	}

	// Corruption is caught by the header checksum.
	bad := slice.clone(buf[:])
	bad[5] ~= 0x40
	_, be := tar_read(bad)
	check(!ok(be), "a flipped header byte is refused")

	// A path climbing out of the root is refused by the reader.
	evil := make([dynamic]byte)
	tar_write(&evil, Tar_Entry{path = "/x", type = .File, mode = 0o644})
	tar_finish(&evil)
	copy(evil[0:100], "../../etc/passwd\x00")
	sum: i64 = 0
	for b, i in evil[:512] {sum += (i >= 148 && i < 156) ? 32 : i64(b)}
	copy(evil[148:156], fmt.tprintf("%06o\x00 ", sum))
	_, ee := tar_read(evil[:])
	check(!ok(ee) && ee.code == EXIT_REFUSED, "a ../ member is refused (%s)", ee.msg)

	// GNU tar's own output, long names and all.
	src := scratch("gnutar/src")
	deep := fmt.tprintf("%s/%s/%s", src, long_dir, long_dir)
	mkdir_p(deep)
	put(fmt.tprintf("%s/file.txt", deep), "from gnu tar")
	tarfile := scratch("gnutar/a.tar")
	code, msg := exec("tar", "--format=gnu", "-C", src, "-cf", tarfile, ".")
	if code != 0 {
		check(false, "host tar ran: %s", msg)
		return
	}
	data := transmute([]byte)slurp(tarfile)
	ge, gerr := tar_read(data)
	check(ok(gerr), "GNU tar archive reads: %s", gerr.msg)
	found := false
	for x in ge {
		if strings.has_suffix(x.path, "/file.txt") && string(x.data) == "from gnu tar" && len(x.path) > 240 {
			found = true
		}
	}
	check(found, "the GNU long-name member is found with its contents")
}

// ---------------------------------------------------------------------------
// gzip
// ---------------------------------------------------------------------------

test_gzip :: proc() {
	section("gzip")
	inputs := make([dynamic][]byte)
	append(&inputs, []byte{})
	append(&inputs, []byte{'x'})
	append(&inputs, transmute([]byte)strings.repeat("a", 100000))
	append(&inputs, transmute([]byte)strings.repeat("abcabcabd", 7777))
	// Pseudo-random bytes: incompressible, so the stored-block path runs.
	rnd := make([]byte, 200000)
	seed: u32 = 12345
	for &b in rnd {
		seed = seed * 1103515245 + 12345
		b = byte(seed >> 16)
	}
	append(&inputs, rnd)
	// Real text, and a real binary: this program.
	if exe, err := os.read_entire_file_from_path(os.args[0], context.allocator); err == nil {
		append(&inputs, exe[:min(len(exe), 600000)])
	}
	for name in ([?]string{"deflate.odin", "main.odin"}) {
		if t, err := os.read_entire_file_from_path(fmt.tprintf("distro/palm/%s", name), context.allocator); err == nil {
			append(&inputs, t)
		}
	}
	// Mixed: text, then noise, then text, across block boundaries.
	mixed := make([dynamic]byte)
	for _ in 0 ..< 3 {
		append(&mixed, ..transmute([]byte)strings.repeat("the quick brown fox ", 3000))
		append(&mixed, ..rnd[:70000])
	}
	append(&inputs, mixed[:])

	for input, i in inputs {
		gz := gzip_compress(input)
		back, okd := gzip_decompress(gz)
		check(okd, "input %d (%d bytes): Odin's decoder accepts it", i, len(input))
		check(okd && slice.equal(back, input), "input %d: round trip is exact", i)
		if len(input) > 1000 && i != 4 {
			check(len(gz) < len(input), "input %d: compressible input shrinks (%d -> %d)", i, len(input), len(gz))
		}
		if i == 4 {
			check(len(gz) < len(input) + len(input) / 100 + 64, "noise grows by less than 1%% (%d -> %d)", len(input), len(gz))
		}
		path := scratch(fmt.tprintf("gz/%d.gz", i))
		mkdir_p(parent_dir(path))
		_ = os.write_entire_file(path, gz)
		code, msg := exec("gzip", "-t", path)
		eq_i(code, 0, "input %d: gzip -t accepts it (%s)", i, msg)
		raw := scratch(fmt.tprintf("gz/%d", i))
		code, msg = exec("sh", "-c", fmt.tprintf("gzip -dc '%s' > '%s'", path, raw))
		eq_i(code, 0, "input %d: gzip -d decodes it (%s)", i, msg)
		check(slurp(raw) == string(input), "input %d: gzip -d gives back the input", i)
	}
	// And the other direction: palm reads what the system gzip writes.
	src := scratch("gz/sys")
	_ = os.write_entire_file(src, inputs[3])
	exec("gzip", "-9", "-k", src)
	back, okd := gzip_decompress(transmute([]byte)slurp(fmt.tprintf("%s.gz", src)))
	check(okd && slice.equal(back, inputs[3]), "system gzip output decodes")
	_, okbad := gzip_decompress([]byte{0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3, 0xff, 0xff})
	check(!okbad, "garbage is refused")
}

// ---------------------------------------------------------------------------
// sha256 and ed25519
// ---------------------------------------------------------------------------

test_crypto :: proc() {
	section("sha256 and ed25519")
	eq_s(sha256_hex(transmute([]byte)string("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256(abc)")
	eq_s(sha256_hex(nil), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha256(empty)")

	// RFC 8032, 7.1, TEST 1.
	sec_path := scratch("rfc.sec")
	put(sec_path, "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60\n")
	priv, e := load_secret(sec_path)
	check(ok(e), "RFC 8032 secret loads")
	sig := sign_bytes(&priv, nil)
	eq_s(sig, "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b", "RFC 8032 test 1 signature")
	pub, okp := parse_public("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
	check(okp, "RFC 8032 public key parses")
	keys := []Trusted_Key{{"rfc.pub", pub}}
	eq_s(verify_any(keys, nil, sig), "rfc.pub", "RFC 8032 signature verifies")

	// palm's own keys.
	name := scratch("keys/test")
	mkdir_p(parent_dir(name))
	eq_i(run("keygen", name), 0, "keygen")
	eq_i(run("keygen", name), EXIT_REFUSED, "keygen will not overwrite a secret key")
	p2, e2 := load_secret(fmt.tprintf("%s.sec", name))
	check(ok(e2), "generated secret loads")
	msg := transmute([]byte)string("PALMINDEX contents")
	s2 := sign_bytes(&p2, msg)
	trusted := load_trusted(parent_dir(name))
	eq_i(len(trusted), 1, "keys dir holds one key")
	eq_s(verify_any(trusted, msg, s2), "test.pub", "own signature verifies")
	tampered := transmute([]byte)string("PALMINDEX contentz")
	eq_s(verify_any(trusted, tampered, s2), "", "a changed message does not verify")
	eq_s(verify_any(keys, msg, s2), "", "another key does not verify it")
	eq_s(verify_any(trusted, msg, "00"), "", "a malformed signature does not verify")
	info, _ := os.stat(fmt.tprintf("%s.sec", name), context.temp_allocator)
	eq_i(int(transmute(u32)info.mode & 0o777), 0o600, "secret key is 0600")
}

// ---------------------------------------------------------------------------
// versions and the resolver
// ---------------------------------------------------------------------------

test_versions :: proc() {
	section("versions")
	ordered := [?]string{"0.9", "1.0_alpha", "1.0_beta2", "1.0_rc1", "1.0", "1.0-r1", "1.0-r2", "1.0_p1", "1.0a", "1.0.1", "1.2.9", "1.2.10", "1.10", "2"}
	for i in 0 ..< len(ordered) {
		for j in 0 ..< len(ordered) {
			want := i < j ? -1 : (i > j ? 1 : 0)
			eq_i(version_compare(ordered[i], ordered[j]), want, "compare %s %s", ordered[i], ordered[j])
		}
	}
	eq_i(version_compare("1.2.10-r0", "1.2.9-r5"), 1, "1.2.10-r0 > 1.2.9-r5")
	eq_i(version_compare("1.02", "1.2"), 0, "leading zeros compare as numbers")
	eq_i(version_compare("1.2-r0", "1.2"), 0, "-r0 is the same as no revision")
	check(version_valid("6.18.56-r0"), "kernel version is valid")
	check(!version_valid("1..2"), "1..2 is not valid")
	check(!version_valid("abc"), "abc is not valid")

	Case :: struct {
		v, c: string,
		want: bool,
	}
	cases := [?]Case {
		{"1.2-r0", "foo", true},
		{"1.2-r0", "foo>=1.2", true},
		{"1.2-r0", "foo>1.2", false},
		{"1.2-r3", "foo=1.2", true},
		{"1.2-r3", "foo=1.2-r2", false},
		{"1.2.5-r0", "foo~1.2", true},
		{"1.20-r0", "foo~1.2", false},
		{"1.1-r9", "foo<1.2", true},
		{"1.2-r0", "foo<=1.2-r0", true},
	}
	for c in cases {
		con, okc := parse_constraint(c.c)
		check(okc, "%s parses", c.c)
		p := Pkg{name = "foo", version = c.v}
		check(pkg_satisfies(&p, con) == c.want, "%s satisfies %s: %v", c.v, c.c, c.want)
	}
	for bad in ([?]string{"", "-x", "foo>=", "foo bar", "../x", "foo>=1..2", "a/b"}) {
		_, okb := parse_constraint(bad)
		check(!okb, "%q is refused as a constraint", bad)
	}
}

@(private = "file")
mkpkg :: proc(name, version: string, depends: []string = nil, provides: []string = nil, installed := false) -> ^Pkg {
	p := new(Pkg)
	p.name = name
	p.version = version
	p.depends = depends
	p.provides = provides
	p.installed = installed
	p.sha256 = fmt.aprintf("%s-%s", name, version)
	return p
}

@(private = "file")
order_names :: proc(res: Resolution) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for p in res.order {append(&out, pkg_id(p))}
	return out[:]
}

@(private = "file")
index_of :: proc(names: []string, s: string) -> int {
	for n, i in names {if n == s {return i}}
	return -1
}

test_resolver :: proc() {
	section("resolver")
	u := new(Universe)
	universe_add(u, mkpkg("app", "1.0-r0", {"libgui>=2", "cmd:sh"}))
	universe_add(u, mkpkg("libgui", "1.5-r0", {"glibc"}))
	universe_add(u, mkpkg("libgui", "2.1-r0", {"glibc", "fonts"}))
	universe_add(u, mkpkg("libgui", "2.0-r0", {"glibc"}))
	universe_add(u, mkpkg("glibc", "2.40-r0"))
	universe_add(u, mkpkg("fonts", "1-r0", {"glibc"}))
	universe_add(u, mkpkg("busybox", "1.37.0-r0", nil, {"cmd:sh", "cmd:ls"}))
	universe_add(u, mkpkg("cycle-a", "1-r0", {"cycle-b"}))
	universe_add(u, mkpkg("cycle-b", "1-r0", {"cycle-a"}))

	res, e := resolve(u, {"app"}, false)
	check(ok(e), "app resolves: %s", e.msg)
	names := order_names(res)
	eq_i(len(names), 5, "five packages chosen (%v)", names)
	check(index_of(names, "libgui-2.1-r0") >= 0, "the newest libgui satisfying >=2 is chosen")
	check(index_of(names, "busybox-1.37.0-r0") >= 0, "cmd:sh is met by its provider")
	check(index_of(names, "glibc-2.40-r0") < index_of(names, "libgui-2.1-r0"), "glibc before libgui")
	check(index_of(names, "fonts-1-r0") < index_of(names, "libgui-2.1-r0"), "fonts before libgui")
	check(index_of(names, "libgui-2.1-r0") < index_of(names, "app-1.0-r0"), "libgui before app")
	eq_s(names[len(names) - 1], "app-1.0-r0", "the requested package comes last")

	_, ce := resolve(u, {"cycle-a"}, false)
	check(ok(ce), "a dependency cycle resolves")

	_, me := resolve(u, {"nonexistent"}, false)
	eq_i(me.code, EXIT_NOT_FOUND, "an unknown package is not found")
	_, ve := resolve(u, {"libgui>=9"}, false)
	eq_i(ve.code, EXIT_NOT_FOUND, "an unsatisfiable version is not found")

	// Installed packages stay put unless upgrading.
	u2 := new(Universe)
	universe_add(u2, mkpkg("foo", "1.0-r0", nil, nil, true))
	universe_add(u2, mkpkg("foo", "2.0-r0"))
	r1, _ := resolve(u2, {"foo"}, false)
	eq_s(pkg_id(r1.chosen["foo"]), "foo-1.0-r0", "add keeps the installed version")
	r2, _ := resolve(u2, {"foo"}, true)
	eq_s(pkg_id(r2.chosen["foo"]), "foo-2.0-r0", "upgrade takes the newest")

	// The repair: foo is chosen first at the installed 1.0, then bar needs
	// foo>=2. The resolver pins and restarts rather than failing.
	universe_add(u2, mkpkg("bar", "1-r0", {"foo>=2"}))
	r3, e3 := resolve(u2, {"foo", "bar"}, false)
	check(ok(e3), "conflict is repaired by a restart: %s", e3.msg)
	if ok(e3) {
		eq_s(pkg_id(r3.chosen["foo"]), "foo-2.0-r0", "the repaired choice satisfies both")
	}
	universe_add(u2, mkpkg("baz", "1-r0", {"foo<1"}))
	_, e4 := resolve(u2, {"bar", "baz"}, false)
	check(!ok(e4), "a genuine conflict is refused")
}

test_http_parser :: proc() {
	section("http responses")
	sized := "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloEXTRA"
	body, status, _, e := http_parse_response(transmute([]byte)sized, "t")
	check(ok(e) && status == 200 && string(body) == "hello", "Content-Length cuts the body")
	chunked := "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n7;ext=1\r\n, world\r\n0\r\n\r\n"
	body, status, _, e = http_parse_response(transmute([]byte)chunked, "t")
	check(ok(e) && string(body) == "hello, world", "chunked body is reassembled (%q)", string(body))
	short := "HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\nhello"
	_, _, _, e = http_parse_response(transmute([]byte)short, "t")
	check(!ok(e), "a truncated body is an error")
	nf := "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n"
	_, status, _, e = http_parse_response(transmute([]byte)nf, "t")
	check(ok(e) && status == 404, "404 is reported as a status, not an error")
	moved := "HTTP/1.1 302 Found\r\nLocation: /x86_64/PALMINDEX\r\nContent-Length: 0\r\n\r\n"
	loc: string
	_, status, loc, _ = http_parse_response(transmute([]byte)moved, "t")
	check(status == 302 && loc == "/x86_64/PALMINDEX", "Location is returned")
	u, oku := parse_http_url("http://10.0.2.2:8080/repo/main")
	check(oku && u.host == "10.0.2.2" && u.port == 8080 && u.path == "/repo/main", "URL parse")
}

// ---------------------------------------------------------------------------
// End to end, by argv
// ---------------------------------------------------------------------------

@(private = "file")
g_key: string
@(private = "file")
g_repo: string

@(private = "file")
write_recipes :: proc() {
	r := scratch("recipes")
	put(fmt.tprintf("%s/hello/hello.sh", r), "#!/bin/sh\necho hello\n", 0o755)
	put(fmt.tprintf("%s/hello/hello.conf", r), "greeting = hi\n")
	put(
		fmt.tprintf("%s/hello/PALMBUILD", r),
		`# a test recipe
pkgname = hello
pkgver  = 1.0
pkgrel  = 0
pkgdesc = Says hello, # with a hash in it
license = MIT
category = Accessories
icon    = terminal
details = The first paragraph.
details = The second one.
depend  = libfoo>=0.5
install_user = palm
file    = hello.sh -> /usr/bin/hello
file    = hello.conf -> /etc/hello/hello.conf
dir     = /var/lib/hello mode 0750
symlink = /usr/bin/hi -> hello
symlink = /etc/hello/current -> hello.conf
owner   = /var/lib/hello palm:palm
mode    = /usr/bin/hello 4755
`,
	)
	put(fmt.tprintf("%s/libfoo/share/a.txt", r), "alpha\n")
	put(fmt.tprintf("%s/libfoo/share/sub/b.txt", r), "beta\n")
	put(fmt.tprintf("%s/libfoo/share/old.txt", r), "dropped in r1\n")
	os.symlink("a.txt", fmt.tprintf("%s/libfoo/share/link", r))
	put(fmt.tprintf("%s/libfoo/PALMBUILD", r), "pkgname = libfoo\npkgver = 0.9.1\npkgdesc = The foo library\nprovides = so:libfoo.so.1\ntree = share -> /usr/share/foo\n")
	put(fmt.tprintf("%s/evil/hello", r), "not hello\n")
	put(fmt.tprintf("%s/evil/PALMBUILD", r), "pkgname = evil\npkgver = 1\nfile = hello -> /usr/bin/hello\n")
}

test_recipes :: proc() {
	section("PALMBUILD")
	write_recipes()
	g_repo = scratch("repo/x86_64")
	g_key = scratch("keys/repo")
	eq_i(run("keygen", g_key), 0, "repository key")
	for name in ([?]string{"hello", "libfoo", "evil"}) {
		eq_i(run("build", scratch(fmt.tprintf("recipes/%s", name)), "-o", g_repo), 0, "build %s: %s", name, g_out)
	}
	check(os.exists(fmt.tprintf("%s/hello-1.0-r0.palm", g_repo)), "hello-1.0-r0.palm is named name-ver-rREL")
	eq_i(run("index", g_repo, "--key", fmt.tprintf("%s.sec", g_key)), 0, "index: %s", g_out)
	check(os.exists(fmt.tprintf("%s/PALMINDEX.sig", g_repo)), "PALMINDEX.sig written")

	// What the archive says, read back.
	data := transmute([]byte)slurp(fmt.tprintf("%s/hello-1.0-r0.palm", g_repo))
	raw, _ := gzip_decompress(data)
	entries, _ := tar_read(raw)
	eq_s(len(entries) > 0 ? entries[0].path : "", ".PKGINFO", ".PKGINFO is the first member")
	for en in entries {
		switch en.path {
		case "/usr/bin/hello":
			eq_i(int(en.mode), 0o4755, "mode override applies")
			eq_s(en.uname, "root", "files default to root")
			eq_i(en.uid, 0, "uid defaults to 0")
		case "/var/lib/hello":
			eq_i(en.uid, 1000, "owner override: uid")
			eq_s(en.gname, "palm", "owner override: group name")
			eq_i(int(en.mode), 0o750, "dir mode")
		case "/usr/bin/hi":
			eq_s(en.link, "hello", "symlink target")
		}
	}
	info, _ := read_pkginfo(data)
	eq_s(info.version, "1.0-r0", ".PKGINFO pkgver carries the release")
	eq_s(info.desc, "Says hello, # with a hash in it", "a # inside a value is kept")
	eq_i(len(info.install_users), 1, "install_user recorded")
	eq_s(info.category, "Accessories", "category recorded in .PKGINFO")
	eq_s(info.icon, "terminal", "icon recorded in .PKGINFO")
	eq_s(info.details, "The first paragraph.\nThe second one.", "details lines are paragraphs")

	// Two builds of the same recipe are the same bytes.
	again := scratch("repo-again")
	run("build", scratch("recipes/hello"), "-o", again)
	eq_s(sha256_hex(transmute([]byte)slurp(fmt.tprintf("%s/hello-1.0-r0.palm", again))), sha256_hex(data), "builds are reproducible")

	// Malformed recipes are refused with the line.
	bad := scratch("recipes/bad")
	cases := [?][2]string {
		{"pkgname = x\npkgver = 1\nbogus = 1\n", "unknown key"},
		{"pkgname = x\npkgver = 1-r2\n", "-r in pkgver"},
		{"pkgname = x\npkgver = 1\ndir = relative/path\n", "relative destination"},
		{"pkgname = x\npkgver = 1\nfile = missing -> /usr/bin/x\n", "missing source"},
		{"pkgname = x\npkgver = 1\ndir = /a\nowner = /a nobody:nobody\n", "unknown owner name"},
		{"pkgname = X Y\npkgver = 1\n", "bad name"},
		{"pkgname = x\npkgver = 1\ndir = /../etc\n", "a path that climbs"},
		{"pkgname = x\npkgver = 1\ncategory = Toys\n", "a category outside the list"},
		{"pkgname = x\npkgver = 1\nicon = Big Icon\n", "an icon that is not a name"},
	}
	for c in cases {
		put(fmt.tprintf("%s/PALMBUILD", bad), c[0])
		code := run("build", bad, "-o", scratch("repo-bad"))
		check(code == EXIT_USAGE || code == EXIT_NOT_FOUND, "%s is refused (exit %d)", c[1], code)
	}
	put(fmt.tprintf("%s/PALMBUILD", bad), "pkgname = x\npkgver = 1\ndir = /home/x\nowner = /home/x/** 1234=4321:users=100\n")
	eq_i(run("build", bad, "-o", scratch("repo-bad")), 0, "name=number owners are accepted")
}

@(private = "file")
installed_version :: proc(root, name: string) -> string {
	o := Opts{root = root}
	db, e := db_open(&o)
	if !ok(e) {return ""}
	p := db_find(db, name)
	return p != nil ? p.version : ""
}

test_lifecycle :: proc() {
	section("build -> index -> add -> verify -> fix -> upgrade -> del")
	root := scratch("root")
	keys := scratch("keys")
	repo := scratch("repo") // the base; palm finds x86_64/ under it

	eq_i(run("--root", root, "add", "hello", "--repo", repo, "--keys-dir", keys), EXIT_NOT_FOUND, "no database without --initdb")
	eq_i(run("--root", root, "--initdb", "--repo", repo, "--keys-dir", keys, "add", "hello", "--dry-run", "--json"), 0, "dry run")
	check(strings.contains(g_out, `"install":[{"name":"libfoo"`), "dry-run JSON plans libfoo first: %s", g_out)
	check(strings.contains(g_out, `"download_size":`) && strings.contains(g_out, `"size_change":`), "the plan carries its sizes: %s", g_out)
	check(!os.exists(fmt.tprintf("%s/usr/bin/hello", root)), "dry run wrote no files")

	code := run("--root", root, "--initdb", "--repo", repo, "--keys-dir", keys, "add", "hello")
	eq_i(code, 0, "add hello: %s", g_out)
	eq_s(slurp(fmt.tprintf("%s/usr/bin/hello", root)), "#!/bin/sh\necho hello\n", "hello is installed")
	eq_s(slurp(fmt.tprintf("%s/usr/share/foo/sub/b.txt", root)), "beta\n", "its dependency is installed")
	target, _ := os.read_link(fmt.tprintf("%s/usr/bin/hi", root), context.temp_allocator)
	eq_s(target, "hello", "symlink installed")
	fi, _ := os.stat(fmt.tprintf("%s/var/lib/hello", root), context.temp_allocator)
	eq_i(int(transmute(u32)fi.mode & 0o777), 0o750, "directory mode applied")
	eq_s(strings.trim_space(slurp(fmt.tprintf("%s/etc/palm/world", root))), "hello", "world holds what was asked for, not dependencies")
	eq_s(installed_version(root, "libfoo"), "0.9.1-r0", "database records libfoo")
	check(!os.exists(fmt.tprintf("%s/usr/bin/.palm-new.hello", root)), "no temporary files left behind")

	R :: proc(root: string, args: ..string) -> int {
		all := make([dynamic]string, context.temp_allocator)
		append(&all, "--root", root, "--repo", scratch("repo"), "--keys-dir", scratch("keys"))
		append(&all, ..args)
		return run(..all[:])
	}

	eq_i(R(root, "verify"), 0, "verify passes after install: %s", g_out)
	eq_i(R(root, "info", "--who-owns", "/usr/share/foo/a.txt"), 0, "who-owns")
	check(strings.contains(g_out, "libfoo"), "who-owns names libfoo")
	eq_i(R(root, "info", "-L", "hello", "--json"), 0, "info -L --json")
	check(strings.contains(g_out, `"/usr/bin/hi"`), "info -L lists the symlink")
	eq_i(R(root, "search", "foo library", "--json"), 0, "search")
	check(strings.contains(g_out, `"name":"libfoo"`), "search finds by description")
	eq_i(R(root, "search", "zzzz"), EXIT_NOT_FOUND, "search for nothing is not found")

	// What a store reads: the store fields survive index and installed
	// database, world decides `explicit`, and reverse dependencies are named.
	eq_i(R(root, "info", "hello", "libfoo", "--json"), 0, "info --json")
	check(strings.contains(g_out, `"category":"Accessories","icon":"terminal","details":"The first paragraph.\nThe second one."`), "info carries category, icon and details: %s", g_out)
	check(strings.contains(g_out, `"name":"hello"`) && strings.contains(g_out, `"explicit":true`), "hello is explicit (in world)")
	check(strings.contains(g_out, `"explicit":false,"required_by":["hello"]`), "libfoo is a dependency, required by hello: %s", g_out)
	eq_i(R(root, "list", "--installed", "--json"), 0, "list --installed --json")
	check(strings.contains(g_out, `"installed_size":`), "list carries installed sizes")
	db_text := slurp(fmt.tprintf("%s/usr/lib/palm/db/installed", root))
	check(strings.contains(db_text, "category = Accessories\n") && strings.contains(db_text, "details = The second one.\n"), "the installed database keeps the store fields")

	// Break things; verify sees it; fix mends it.
	put(fmt.tprintf("%s/usr/share/foo/a.txt", root), "tampered\n")
	_ = os.remove(fmt.tprintf("%s/usr/share/foo/sub/b.txt", root))
	put(fmt.tprintf("%s/etc/hello/hello.conf", root), "greeting = mine\n")
	// A retargeted link under /etc is configuration too (/etc/localtime).
	_ = os.remove(fmt.tprintf("%s/etc/hello/current", root))
	os.symlink("mine.conf", fmt.tprintf("%s/etc/hello/current", root))
	eq_i(R(root, "verify"), EXIT_FAILED_GENERIC, "verify fails on a changed and a missing file")
	check(strings.contains(g_out, "/etc/hello/current: modified (config): points to mine.conf"), "a retargeted /etc link is reported softly: %s", g_out)
	check(strings.contains(g_out, "sha256 mismatch") && strings.contains(g_out, "missing"), "verify names both problems: %s", g_out)
	check(strings.contains(g_out, "modified (config)"), "an edited config is reported softly")
	eq_i(R(root, "fix"), 0, "fix: %s", g_out)
	eq_s(slurp(fmt.tprintf("%s/usr/share/foo/a.txt", root)), "alpha\n", "fix restored the changed file")
	eq_s(slurp(fmt.tprintf("%s/usr/share/foo/sub/b.txt", root)), "beta\n", "fix restored the missing file")
	eq_i(R(root, "verify"), 0, "verify passes after fix: %s", g_out)
	cur, _ := os.read_link(fmt.tprintf("%s/etc/hello/current", root), context.temp_allocator)
	eq_s(cur, "mine.conf", "fix keeps a retargeted /etc link")

	// Conflicts: evil also ships /usr/bin/hello.
	eq_i(R(root, "add", "evil"), EXIT_REFUSED, "a file conflict is refused")
	check(strings.contains(g_out, "/usr/bin/hello is in both hello and evil"), "the conflict is named: %s", g_out)
	eq_s(slurp(fmt.tprintf("%s/usr/bin/hello", root)), "#!/bin/sh\necho hello\n", "the refused package changed nothing")
	eq_s(installed_version(root, "evil"), "", "evil is not recorded")

	// Upgrade: a new libfoo release that drops a file, and a new hello whose
	// config changed under a locally edited one.
	put(scratch("recipes/libfoo/PALMBUILD"), "pkgname = libfoo\npkgver = 0.9.1\npkgrel = 1\npkgdesc = The foo library\nprovides = so:libfoo.so.1\ntree = share -> /usr/share/foo\n")
	_ = os.remove(scratch("recipes/libfoo/share/old.txt"))
	put(scratch("recipes/hello/hello.conf"), "greeting = hello there\n")
	put(scratch("recipes/hello/PALMBUILD"), strings.concatenate({slurp(scratch("recipes/hello/PALMBUILD")), "pkgrel = 1\n"}))
	run("build", scratch("recipes/libfoo"), "-o", g_repo)
	run("build", scratch("recipes/hello"), "-o", g_repo)
	eq_i(run("index", g_repo, "--key", fmt.tprintf("%s.sec", g_key)), 0, "reindex")
	eq_i(R(root, "list", "--upgradable"), 0, "list --upgradable")
	check(strings.contains(g_out, "libfoo-0.9.1-r1 [upgradable from: 0.9.1-r0]"), "libfoo is upgradable: %s", g_out)
	eq_i(R(root, "add", "hello"), 0, "add of an installed package")
	eq_s(installed_version(root, "libfoo"), "0.9.1-r0", "add does not upgrade what is installed")
	eq_i(R(root, "upgrade"), 0, "upgrade: %s", g_out)
	eq_s(installed_version(root, "libfoo"), "0.9.1-r1", "libfoo upgraded")
	eq_s(installed_version(root, "hello"), "1.0-r1", "hello upgraded")
	check(!os.exists(fmt.tprintf("%s/usr/share/foo/old.txt", root)), "a file dropped by the new version is removed")
	eq_s(slurp(fmt.tprintf("%s/etc/hello/hello.conf", root)), "greeting = mine\n", "the edited config is kept")
	eq_s(slurp(fmt.tprintf("%s/etc/hello/hello.conf.palm-new", root)), "greeting = hello there\n", "the new config is beside it as .palm-new")
	cur, _ = os.read_link(fmt.tprintf("%s/etc/hello/current", root), context.temp_allocator)
	eq_s(cur, "mine.conf", "upgrade keeps a retargeted /etc link")

	// del: hello goes, and libfoo goes with it because nothing needs it.
	eq_i(R(root, "del", "libfoo"), 0, "del of a dependency")
	eq_s(installed_version(root, "libfoo"), "0.9.1-r1", "a dependency still required stays")
	eq_i(R(root, "del", "hello", "--yes"), 0, "del hello: %s", g_out)
	eq_s(installed_version(root, "hello"), "", "hello is gone")
	eq_s(installed_version(root, "libfoo"), "", "the orphaned dependency is gone")
	check(!os.exists(fmt.tprintf("%s/usr/bin/hello", root)), "hello's files are gone")
	check(!os.exists(fmt.tprintf("%s/usr/share/foo", root)), "libfoo's directories are gone")
	check(os.exists(fmt.tprintf("%s/etc/hello/hello.conf", root)), "the edited config survives removal")
	check(os.exists(fmt.tprintf("%s/usr/lib/palm/db/installed", root)), "the database stays")
	eq_s(strings.trim_space(slurp(fmt.tprintf("%s/etc/palm/world", root))), "", "world is empty")
	eq_i(R(root, "del", "hello"), EXIT_NOT_FOUND, "del of something not installed")
}

test_tampering :: proc() {
	section("tampering")
	keys := scratch("keys")
	// A copy of the repository to damage.
	bad := scratch("badrepo")
	mkdir_p(bad)
	for f in ([?]string{"PALMINDEX", "PALMINDEX.sig", "hello-1.0-r1.palm", "libfoo-0.9.1-r1.palm"}) {
		os.copy_file(fmt.tprintf("%s/%s", bad, f), fmt.tprintf("%s/%s", g_repo, f))
	}
	root := scratch("root-t")
	A :: proc(root, repo: string, extra: ..string) -> int {
		all := make([dynamic]string, context.temp_allocator)
		append(&all, "--root", root, "--initdb", "--repo", repo, "--keys-dir", scratch("keys"))
		append(&all, ..extra)
		append(&all, "add", "hello")
		return run(..all[:])
	}

	// 1. A package whose bytes differ from its signed index record.
	evil := transmute([]byte)slurp(fmt.tprintf("%s/evil-1-r0.palm", g_repo))
	_ = os.write_entire_file(fmt.tprintf("%s/libfoo-0.9.1-r1.palm", bad), evil)
	eq_i(A(root, bad), EXIT_REFUSED, "a swapped package is refused")
	check(strings.contains(g_out, "sha256 mismatch"), "the refusal says why: %s", g_out)
	check(!os.exists(fmt.tprintf("%s/usr/bin/hello", root)), "nothing was installed")
	eq_i(A(root, bad, "--allow-untrusted"), EXIT_REFUSED, "--allow-untrusted does not excuse a sha256 mismatch")
	os.copy_file(fmt.tprintf("%s/libfoo-0.9.1-r1.palm", bad), fmt.tprintf("%s/libfoo-0.9.1-r1.palm", g_repo))

	// 2. An index edited after signing.
	idx := slurp(fmt.tprintf("%s/PALMINDEX", bad))
	put(fmt.tprintf("%s/PALMINDEX", bad), replace(idx, "Says hello", "Says goodbye"))
	eq_i(A(root, bad), EXIT_REFUSED, "an edited index is refused")
	check(strings.contains(g_out, "signature"), "the refusal names the signature: %s", g_out)
	check(!os.exists(fmt.tprintf("%s/usr/bin/hello", root)), "nothing was installed")

	// 3. No signature at all.
	put(fmt.tprintf("%s/PALMINDEX", bad), idx)
	_ = os.remove(fmt.tprintf("%s/PALMINDEX.sig", bad))
	eq_i(A(root, bad), EXIT_REFUSED, "an unsigned index is refused")
	eq_i(A(root, bad, "--allow-untrusted"), 0, "--allow-untrusted accepts an unsigned index whose packages match it")
	check(os.exists(fmt.tprintf("%s/usr/bin/hello", root)), "and installs")

	// 4. Signed, but by a key nobody trusts.
	other := scratch("other/k")
	mkdir_p(parent_dir(other))
	run("keygen", other)
	run("index", bad, "--key", fmt.tprintf("%s.sec", other))
	root2 := scratch("root-t2")
	eq_i(A(root2, bad), EXIT_REFUSED, "an index signed by an untrusted key is refused")
	all := make([dynamic]string, context.temp_allocator)
	append(&all, "--root", root2, "--initdb", "--repo", bad, "--keys-dir", parent_dir(other), "add", "hello")
	eq_i(run(..all[:]), 0, "trusting that key accepts it")

	// 5. A local file needs --allow-untrusted.
	root3 := scratch("root-t3")
	pkgfile := fmt.tprintf("%s/libfoo-0.9.1-r1.palm", g_repo)
	eq_i(run("--root", root3, "--initdb", "--repo", g_repo, "--keys-dir", keys, "add", pkgfile), EXIT_REFUSED, "a local .palm is refused without --allow-untrusted")
	eq_i(run("--root", root3, "--initdb", "--repo", g_repo, "--keys-dir", keys, "--allow-untrusted", "add", pkgfile), 0, "and accepted with it: %s", g_out)
	eq_s(installed_version(root3, "libfoo"), "0.9.1-r1", "the local package is installed")
}

// ---------------------------------------------------------------------------
// A real HTTP repository
// ---------------------------------------------------------------------------

test_http_repo :: proc() {
	section("http repository (python3 -m http.server)")
	serve := scratch("serve")
	mkdir_p(fmt.tprintf("%s/main/x86_64", serve))
	for f in ([?]string{"PALMINDEX", "PALMINDEX.sig", "hello-1.0-r1.palm", "libfoo-0.9.1-r1.palm"}) {
		os.copy_file(fmt.tprintf("%s/main/x86_64/%s", serve, f), fmt.tprintf("%s/%s", g_repo, f))
	}
	port := 20000 + os.get_pid() % 20000
	null, _ := os.open("/dev/null", {.Write})
	server, err := os.process_start(os.Process_Desc{command = {"python3", "-m", "http.server", fmt.tprintf("%d", port), "--bind", "127.0.0.1", "--directory", serve}, stdout = null, stderr = null})
	if err != nil {
		check(false, "python3 http.server started: %v", err)
		return
	}
	defer {
		_ = os.process_kill(server)
		_, _ = os.process_wait(server)
		os.close(null)
	}
	url := fmt.tprintf("http://127.0.0.1:%d/main", port)
	up := false
	for _ in 0 ..< 100 {
		_, status, e := http_get(fmt.tprintf("%s/x86_64/PALMINDEX", url), context.temp_allocator)
		if ok(e) && status == 200 {
			up = true
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	check(up, "the server answered")
	if !up {return}

	root := scratch("root-http")
	keys := scratch("keys")
	H :: proc(root, url: string, args: ..string) -> int {
		all := make([dynamic]string, context.temp_allocator)
		append(&all, "--root", root, "--initdb", "--repo", url, "--keys-dir", scratch("keys"))
		append(&all, ..args)
		return run(..all[:])
	}
	eq_i(H(root, url, "update", "--json"), 0, "update over http: %s", g_out)
	check(strings.contains(g_out, `"signed_by":"repo.pub"`), "the index verified against the trusted key: %s", g_out)
	eq_i(H(root, url, "add", "hello"), 0, "add over http: %s", g_out)
	eq_s(slurp(fmt.tprintf("%s/usr/bin/hello", root)), "#!/bin/sh\necho hello\n", "hello installed from http")
	eq_i(H(root, url, "verify"), 0, "verify")
	cache := fmt.tprintf("%s/var/cache/palm", root)
	infos, _ := os.read_all_directory_by_path(cache, context.temp_allocator)
	cached := false
	for d in infos {
		if os.exists(fmt.tprintf("%s/hello-1.0-r1.palm", d.fullpath)) && os.exists(fmt.tprintf("%s/PALMINDEX", d.fullpath)) {
			cached = true
		}
	}
	check(cached, "index and package are cached under /var/cache/palm")

	// Tamper with what the server serves; the cached copy is re-verified too.
	idx_path := fmt.tprintf("%s/main/x86_64/PALMINDEX", serve)
	put(idx_path, replace(slurp(idx_path), "The foo library", "The evil library"))
	eq_i(H(root, url, "update"), EXIT_REFUSED, "a tampered index over http is refused")
	root2 := scratch("root-http2")
	eq_i(H(root2, url, "add", "hello"), EXIT_REFUSED, "and nothing installs from it")
	check(!os.exists(fmt.tprintf("%s/usr/bin/hello", root2)), "no files written")

	// The base URL without the arch directory works too.
	flat := scratch("serve/flat")
	mkdir_p(flat)
	for f in ([?]string{"PALMINDEX", "PALMINDEX.sig", "hello-1.0-r1.palm", "libfoo-0.9.1-r1.palm"}) {
		os.copy_file(fmt.tprintf("%s/%s", flat, f), fmt.tprintf("%s/%s", g_repo, f))
	}
	root3 := scratch("root-http3")
	eq_i(H(root3, fmt.tprintf("http://127.0.0.1:%d/flat", port), "add", "hello", "--no-cache"), 0, "a repository without x86_64/ works: %s", g_out)
	_ = keys

	// Unreachable: a warning for update, not a crash.
	eq_i(H(scratch("root-http4"), "http://127.0.0.1:1/none", "update"), EXIT_UNAVAILABLE, "an unreachable repository is reported as unavailable")
}

// ---------------------------------------------------------------------------
// The command surface passthrough
// ---------------------------------------------------------------------------

test_passthrough :: proc() {
	section("passthrough to the command surface")
	fake := scratch("fake-surface")
	argv_file := scratch("surface-argv")
	put(fake, fmt.tprintf("#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done > '%s'\nexit 42\n", argv_file), 0o755)
	self, _ := os.get_executable_path(context.allocator)
	env, _ := os.environ(context.allocator)
	envs := make([dynamic]string)
	append(&envs, ..env)
	append(&envs, fmt.tprintf("PALM_SURFACE=%s", fake))

	state, _, _, err := os.process_exec(os.Process_Desc{command = {self, "notes", "list", "--json"}, env = envs[:]}, context.allocator)
	check(err == nil, "ran self")
	eq_i(state.exit_code, 42, "the surface's exit code comes back")
	eq_s(slurp(argv_file), "notes\nlist\n--json\n", "argv is handed over untouched")

	_ = os.remove(argv_file)
	state, _, _, err = os.process_exec(os.Process_Desc{command = {self, "info"}, env = envs[:]}, context.allocator)
	eq_i(state.exit_code, EXIT_USAGE, "a palm verb is not passed through")
	check(!os.exists(argv_file), "the surface did not run for a palm verb")
}
