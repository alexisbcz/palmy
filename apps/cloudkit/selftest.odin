package cloudkit

// The self-test: the framing and helpers offline, then — when a stack
// answers at the URL — the whole client against it, including the claim the
// design is held to, from the client's side.
//
//	odin test apps/cloudkit                     # runs selftest(live = true)
//	accounts --selftest                         # the same, from the app
//
// The live half signs up a throwaway account (selftest-<random>@palm.test)
// and uses a throwaway token store under /tmp, never the real one.

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
T :: struct {
	pass, fail: int,
	quiet:      bool,
}

@(private = "file")
check :: proc(t: ^T, cond: bool, what: string, args: ..any) {
	if cond {
		t.pass += 1
		if !t.quiet {
			fmt.eprintfln("ok   %s", fmt.tprintf(what, ..args))
		}
	} else {
		t.fail += 1
		fmt.eprintfln("FAIL %s", fmt.tprintf(what, ..args))
	}
}

@(private = "file")
check_err :: proc(t: ^T, e: Error, want: Error_Kind, what: string) {
	if e.kind == want {
		check(t, true, what)
	} else {
		check(t, false, "%s (got %s: %s %s)", what, error_kind_name(e.kind), e.code, e.message)
	}
}

// selftest runs everything and returns (passed, failed).
selftest :: proc(live := true, url := "", quiet := false) -> (passed, failed: int) {
	t := T{quiet = quiet}
	offline(&t)
	if live {
		online(&t, url)
	}
	return t.pass, t.fail
}

@(test)
cloudkit_selftest :: proc(tt: ^testing.T) {
	p, f := selftest()
	testing.expectf(tt, f == 0, "%d of %d checks failed", f, p + f)
}

// ---------------------------------------------------------------------------
// Offline
// ---------------------------------------------------------------------------

@(private = "file")
decode_all :: proc(wire: string, step: int) -> (status: int, body: string, bad: string) {
	d := decoder_make()
	defer decoder_destroy(&d)
	out := make([dynamic]u8, context.temp_allocator)
	data := transmute([]u8)wire
	for i := 0; i < len(data); i += step {
		decoder_feed(&d, data[i:min(i + step, len(data))], &out)
	}
	if !decoder_done(&d) {
		decoder_eof(&d)
	}
	return d.status, string(out[:]), d.bad
}

@(private = "file")
offline :: proc(t: ^T) {
	u, uok := parse_url("http://127.0.0.1:54321")
	check(t, uok && u.host == "127.0.0.1" && u.port == 54321 && !u.tls && u.base == "", "parse_url: host and port")
	u, uok = parse_url("https://cloud.palmy.org/base/")
	check(t, uok && u.tls && u.port == 443 && u.base == "/base", "parse_url: https, default port, base path")
	_, uok = parse_url("ftp://x")
	check(t, !uok, "parse_url: refuses other schemes")
	_, uok = parse_url("http://host:99999")
	check(t, !uok, "parse_url: refuses a bad port")

	chunked := "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n4\r\n{\"a\"\r\nC;ext=1\r\n:\"ünïcode\"\r\n1\r\n}\r\n0\r\nTrailer: x\r\n\r\n"
	for step in ([]int{1, 2, 3, 7, 1000}) {
		st, body, bad := decode_all(chunked, step)
		check(t, bad == "" && st == 200 && body == `{"a":"ünïcode"}`, "decoder: chunked with a 100, an extension and a trailer, %d-byte reads", step)
	}
	st, body, bad := decode_all("HTTP/1.1 201 Created\r\nContent-Length: 5\r\n\r\nhelloEXTRA", 3)
	check(t, bad == "" && st == 201 && body == "hello", "decoder: Content-Length stops at the length")
	st, body, bad = decode_all("HTTP/1.0 200 OK\r\n\r\nuntil close", 4)
	check(t, bad == "" && body == "until close", "decoder: no framing reads to close")
	st, body, bad = decode_all("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n", 1)
	check(t, bad == "" && st == 204 && body == "", "decoder: 204 has no body")
	_, _, bad = decode_all("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort", 2)
	check(t, bad != "", "decoder: a truncated body is an error")
	_, _, bad = decode_all("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n", 2)
	check(t, bad != "", "decoder: a bad chunk size is an error")
	_, _, bad = decode_all("SSH-2.0-OpenSSH\r\n", 5)
	check(t, bad != "", "decoder: not HTTP is an error")

	check(t, quote("a\"b\\c\nd\x01") == `"a\"b\\c\nd\u0001"`, "quote escapes")
	o := obj()
	put(&o, "s", "x")
	put(&o, "n", i64(3))
	put(&o, "b", true)
	check(t, obj_done(&o) == `{"s":"x","n":3,"b":true}`, "obj builds an object")
	check(t, escape("a b/c&d") == "a%20b%2Fc%26d" && escape("a b/c", keep_slash = true) == "a%20b/c", "escape")

	check(t, handle_ok("alice.work") && handle_ok("a1") && !handle_ok("../x") && !handle_ok("Alice") && !handle_ok("-x"), "handle_ok")
	claims, cok := jwt_claims(DEFAULT_ANON_KEY, context.temp_allocator)
	check(t, cok && get_str(claims, "role") == "anon", "jwt_claims reads the anon key")
	_, cok = jwt_claims("not.a-token", context.temp_allocator)
	check(t, !cok, "jwt_claims refuses garbage")

	ev, _ := parse(`{"code":"42501","message":"permission denied"}`, context.temp_allocator)
	check(t, error_from(403, ev).kind == .Out_Of_Scope, "error_from: PostgREST 42501")
	ev, _ = parse(`{"statusCode":"403","error":"Unauthorized","message":"new row violates row-level security policy"}`, context.temp_allocator)
	check(t, error_from(400, ev).kind == .Out_Of_Scope, "error_from: Storage RLS refusal")
	ev, _ = parse(`{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}`, context.temp_allocator)
	check(t, error_from(400, ev).kind == .Unauthorized, "error_from: wrong password")
	ev, _ = parse(`{"code":"23505","message":"duplicate key"}`, context.temp_allocator)
	check(t, error_from(409, ev).kind == .Conflict, "error_from: taken handle")

	dir := scratch_dir("offline")
	defer os.remove_all(dir)
	path := pjoin({dir, "store", "session.json"}, context.temp_allocator)
	e := write_private(path, "{}")
	fi, _ := os.stat(path, context.temp_allocator)
	di, _ := os.stat(pjoin({dir, "store"}, context.temp_allocator), context.temp_allocator)
	check(t, ok(e) && fi.mode & os.perm_number(0o777) == os.perm_number(0o600), "write_private: file is 0600")
	check(t, di.mode & os.perm_number(0o777) == os.perm_number(0o700), "write_private: directory is 0700")

	// make_dirs under an ancestor that may be passed through but not read
	// (mode 0111): what the Landlock sandbox does to $HOME. core:os's
	// make_directory_all opens that ancestor and gives up; make_dirs does not.
	{
		locked := pjoin({dir, "locked"}, context.temp_allocator)
		root := pjoin({locked, "Notes", "camille.roux"}, context.temp_allocator)
		check(t, make_dirs(root), "make_dirs: creates every missing level")
		os.chmod(locked, os.perm_number(0o111))
		deep := pjoin({root, "Travel", "2026"}, context.temp_allocator)
		_ = os.make_directory_all(pjoin({root, "Other", "x"}, context.temp_allocator))
		blind := !os.is_dir(pjoin({root, "Other"}, context.temp_allocator))
		check(t, make_dirs(deep) && os.is_dir(deep), "make_dirs: below an unreadable ancestor, where make_directory_all could not (it %s)", blind ? "failed, as expected" : "worked: running as root?")
		check(t, make_dirs(deep), "make_dirs: an existing directory is fine")
		check(t, make_dirs("/") && !make_dirs(""), "make_dirs: / exists, \"\" is nothing")
		os.chmod(locked, os.perm_number(0o700))
	}

	saved := tls_dial
	tls_dial = nil
	_, terr := http_do(Url{tls = true, host = "example.org", port = 443}, Request{method = "GET", path = "/"})
	check(t, strings.contains(terr, "TLS"), "https without a TLS transport is refused, not sent in the clear")
	tls_dial = saved
}

@(private = "file")
scratch_dir :: proc(tag: string) -> string {
	d := fmt.tprintf("/tmp/cloudkit-selftest-%s-%d-%x", tag, os.get_pid(), rand.uint32())
	os.make_directory_all(d)
	return d
}

// ---------------------------------------------------------------------------
// Online
// ---------------------------------------------------------------------------

@(private = "file")
online :: proc(t: ^T, url: string) {
	dir := scratch_dir("live")
	defer os.remove_all(dir)

	person, oerr := open(url = url, dir = dir, scope = "-", app = "selftest")
	// scope "-" is not a handle: open must refuse it rather than treat it
	// as unscoped.
	check_err(t, oerr, .Invalid, "open: an invalid PALM_IDENTITY is refused")
	close(person)

	person, oerr = open(url = url, dir = dir, app = "selftest")
	defer close(person)
	probe, perr := call(person, "GET", "/auth/v1/health", "", auth = false, allocator = context.temp_allocator)
	_ = probe
	if perr.kind == .Unavailable {
		fmt.eprintfln("skip live checks: no stack at %s (%s)", person.url_text, perr.message)
		return
	}
	if !ok(oerr) {
		check(t, false, "open: %s", oerr.message)
		return
	}

	tag := fmt.tprintf("%x", rand.uint64())
	email := fmt.tprintf("selftest-%s@palm.test", tag)
	password := fmt.tprintf("pw-%s-long-enough", tag)
	check_err(t, sign_up(person, email, password), .None, "sign up")
	check(t, signed_in(person) && !scoped(person), "signed in, unscoped")
	sfile := pjoin({dir, "session.json"}, context.temp_allocator)
	fi, _ := os.stat(sfile, context.temp_allocator)
	check(t, fi.mode & os.perm_number(0o777) == os.perm_number(0o600), "session.json is 0600")
	check_err(t, sign_up(person, email, password), .Conflict, "signing up twice is a conflict")

	home, e := create_identity(person, fmt.tprintf("home-%s", tag[:8]), "Home", "personal", "emerald", context.temp_allocator)
	check_err(t, e, .None, "create a personal identity")
	work: Identity
	work, e = create_identity(person, fmt.tprintf("work-%s", tag[:8]), "Work", "work", "sky", context.temp_allocator)
	check_err(t, e, .None, "create a work identity")
	_, e = create_identity(person, fmt.tprintf("home-%s", tag[:8]), "Again", allocator = context.temp_allocator)
	check_err(t, e, .Conflict, "a taken handle is a conflict")
	_, e = create_identity(person, "postmaster", "Mail", allocator = context.temp_allocator)
	check_err(t, e, .Invalid, "a reserved handle is invalid")
	renamed: Identity
	renamed, e = rename_identity(person, home.id, "Home life", context.temp_allocator)
	check(t, ok(e) && renamed.display_name == "Home life", "rename")

	check_err(t, set_current_identity(person, work.handle), .None, "set the current identity")
	check(t, current_identity(person, context.temp_allocator) == work.handle, "the current identity persists")

	_, e = update(person, "profiles", fmt.tprintf("identity_id=eq.%s", home.id), `{"bio":"home bio"}`, context.temp_allocator)
	check_err(t, e, .None, "the person writes the home profile")

	// A scoped session for work, as an assistant would hold.
	m: Minted
	m, e = scope_to(person, work, "selftest assistant", "assistant")
	check_err(t, e, .None, "mint a session scoped to work")
	wfile := pjoin({dir, "scoped", fmt.tprintf("%s.json", work.handle)}, context.temp_allocator)
	fi, _ = os.stat(wfile, context.temp_allocator)
	check(t, os.exists(wfile) && fi.mode & os.perm_number(0o777) == os.perm_number(0o600), "the scoped session is stored 0600 under its handle")

	scope, serr := open(url = url, dir = dir, scope = work.handle, app = "selftest")
	defer close(scope)
	check(t, ok(serr) && signed_in(scope) && scope.session.identity_id == work.id, "PALM_IDENTITY=<work> opens the work session")
	nobody, _ := open(url = url, dir = dir, scope = home.handle, app = "selftest")
	check(t, !signed_in(nobody), "PALM_IDENTITY=<home> has no session, and does not fall back to the person's")
	close(nobody)

	xs: []Identity
	xs, e = identities(scope, context.temp_allocator)
	check(t, ok(e) && len(xs) == 1 && xs[0].id == work.id, "scoped: sees exactly its identity")
	rows: Value
	rows, e = select(scope, "profiles", fmt.tprintf("identity_id=eq.%s", home.id), context.temp_allocator)
	check(t, ok(e) && len(array(rows)) == 0, "scoped: the home profile is invisible")
	rows, e = update(scope, "profiles", fmt.tprintf("identity_id=eq.%s", home.id), `{"bio":"overwritten"}`, context.temp_allocator)
	check(t, ok(e) && len(array(rows)) == 0, "scoped: updating the home profile matches nothing")
	_, e = insert(scope, "profiles", one("identity_id", home.id), context.temp_allocator)
	check_err(t, e, .Out_Of_Scope, "scoped: inserting for home is refused")
	_, e = rpc(scope, "mint_scoped_session", two("target", home.id, "device_name", "escape"), context.temp_allocator)
	check_err(t, e, .Out_Of_Scope, "scoped: cannot mint for home")
	check_err(t, sign_in(scope, email, password), .Out_Of_Scope, "scoped: the client refuses to sign in as the person")
	_, e = call(scope, "PUT", "/auth/v1/user", `{"password":"taken-over-123"}`, allocator = context.temp_allocator)
	check_err(t, e, .Out_Of_Scope, "scoped: the gateway refuses an account change")
	who: Value
	who, e = whoami(scope, context.temp_allocator)
	check(t, ok(e) && get_str(who, "identity", "id") == work.id, "whoami names the scope")
	rows, e = select(person, "profiles", fmt.tprintf("identity_id=eq.%s&select=bio", home.id), context.temp_allocator)
	check(t, ok(e) && get_str(array(rows)[0] if len(array(rows)) > 0 else nil, "bio") == "home bio", "the home profile is unchanged")

	// Storage, streamed both ways.
	img := pjoin({dir, "avatar.png"}, context.temp_allocator)
	big := make([]u8, 1_500_000, context.temp_allocator)
	for i in 0 ..< len(big) {
		big[i] = u8(rand.uint32())
	}
	copy(big[:8], []u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'})
	_ = os.write_entire_file(img, big)
	check_err(t, set_avatar(scope, work.id, img), .None, "scoped: uploads its own avatar (1.5 MB, streamed)")
	check_err(t, set_avatar(scope, home.id, img), .Out_Of_Scope, "scoped: uploading home's avatar is refused")
	check_err(t, set_avatar(person, home.id, img), .None, "the person uploads home's avatar")
	back := pjoin({dir, "back.png"}, context.temp_allocator)
	check_err(t, download_file(person, AVATAR_BUCKET, fmt.tprintf("%s/avatar.png", work.id), back), .None, "download streams to a file")
	got, _ := os.read_entire_file_from_path(back, context.temp_allocator)
	check(t, len(got) == len(big) && string(got) == string(big), "the download is byte-identical")
	check_err(t, download_file(scope, AVATAR_BUCKET, fmt.tprintf("%s/avatar.png", home.id), back), .Not_Found, "scoped: home's avatar does not exist for it")
	data: []u8
	data, e = download_bytes(scope, AVATAR_BUCKET, fmt.tprintf("%s/avatar.png", work.id), context.temp_allocator)
	check(t, ok(e) && len(data) == len(big), "download_bytes")
	ls: Value
	ls, e = list(scope, AVATAR_BUCKET, work.id, allocator = context.temp_allocator)
	check(t, ok(e) && len(array(ls)) == 1 && get_str(array(ls)[0], "name") == "avatar.png", "list one folder")
	ls, e = list(scope, AVATAR_BUCKET, home.id, allocator = context.temp_allocator)
	check(t, ok(e) && len(array(ls)) == 0, "scoped: listing home's folder shows nothing")

	// Devices and sessions, then revocation.
	devs: []Device
	devs, e = devices(person, context.temp_allocator)
	check(t, ok(e) && len(devs) == 1 && devs[0].active && devs[0].kind == "assistant", "the person sees the assistant device")
	ss: []Account_Session
	ss, e = sessions(person, context.temp_allocator)
	check(t, ok(e) && len(ss) == 2, "the account has two sessions (got %d)", len(ss))
	ss, e = sessions(scope, context.temp_allocator)
	check(t, ok(e) && len(ss) == 1 && ss[0].current, "scoped: lists only itself")
	check_err(t, revoke_device(person, m.device_id), .None, "the person revokes the device")
	_, e = identities(scope, context.temp_allocator)
	check(t, !ok(e) && (e.kind == .Unauthorized || e.kind == .Invalid), "revoked: the scoped client is refused at once (%s)", error_kind_name(e.kind))
	check(t, !signed_in(scope) && !os.exists(wfile), "revoked: the scoped client forgot its session")

	check_err(t, sign_out(person), .None, "sign out")
	check(t, !signed_in(person) && !os.exists(sfile), "signed out: the session file is gone")
	check_err(t, sign_in(person, email, "wrong password"), .Unauthorized, "a wrong password is refused")
	check_err(t, sign_in(person, email, password), .None, "sign in again")
	_, e = archive_identity(person, work.id, context.temp_allocator)
	check_err(t, e, .None, "archive the work identity")
	_, e = scope_to(person, work, "late")
	check_err(t, e, .Out_Of_Scope, "no session for an archived identity")
	check_err(t, sign_out(person), .None, "sign out again")
}
