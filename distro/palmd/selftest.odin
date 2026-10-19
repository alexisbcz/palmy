package palmd

// palmd --selftest
//
// Three layers, in the order they can fail:
//
//  1. the pure parts: package-name and request validation (including the
//     shapes an attacker would try: options, shell metacharacters, paths,
//     extra fields), palm's argv, plan ids, framing, the authorization rule
//     against fixture passwd and group files;
//  2. SO_PEERCRED on a real socketpair: the kernel's answer is this process;
//  3. the daemon itself, end to end: this binary started as
//     `palmd --test` against a fake palm (a shell script that records its
//     argv and prints what palm would), driven over its socket the way the
//     store drives it -- plan, apply with the right and a wrong plan id,
//     progress streaming, palm's error passed through verbatim, update, busy,
//     a malicious name, and a group file edited to remove the caller, which
//     must turn the next connection away.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

@(private = "file")
g_fail := 0
@(private = "file")
g_count := 0

@(private = "file")
check :: proc(okk: bool, what: string, args: ..any) {
	g_count += 1
	if !okk {
		g_fail += 1
		fmt.printf("  FAIL: ")
		fmt.printfln(what, ..args)
	}
}

@(private = "file")
section :: proc(name: string) {
	fmt.printfln("%s", name)
}

selftest :: proc() -> int {
	start := time.tick_now()
	test_names()
	test_requests()
	test_argv_and_ids()
	test_framing()
	test_authorize()
	test_peercred()
	test_daemon()
	fmt.printfln("\n%d assertions, %d failures, %v", g_count, g_fail, time.tick_since(start))
	return g_fail == 0 ? 0 : 1
}

@(private = "file")
test_names :: proc() {
	section("package names")
	for good in ([?]string{"track", "libxkbcommon", "fonts-emoji", "gtk+3", "python3.12", "a", "0ad", "x_y"}) {
		check(name_valid(good), "%q is a name", good)
	}
	for bad in ([?]string {
		"",
		"--root=/",
		"-y",
		"x;rm",
		"x rm",
		"../etc",
		"/usr/bin/x",
		"Track",
		"x$(id)",
		"x`id`",
		"x\nrm",
		".hidden",
		"+x",
		"x|y",
		"x>y",
		"ä",
	}) {
		check(!name_valid(bad), "%q is refused", bad)
	}
	long := strings.repeat("a", MAX_NAME + 1, context.temp_allocator)
	check(!name_valid(long), "a %d-byte name is refused", len(long))
}

@(private = "file")
test_requests :: proc() {
	section("requests")
	r, why := parse_request(`{"op":"plan","action":"add","packages":["track","emoji","track"]}`)
	check(why == "" && r.op == .Plan && r.action == .Add, "a plan parses: %s", why)
	check(len(r.packages) == 2, "duplicates collapse (%d)", len(r.packages))

	r, why = parse_request(`{"op":"update"}`)
	check(why == "" && r.op == .Update, "update parses: %s", why)

	r, why = parse_request(`{"op":"plan","action":"upgrade"}`)
	check(why == "" && r.action == .Upgrade, "upgrade with no packages parses: %s", why)

	id := strings.repeat("ab", 16, context.temp_allocator)
	r, why = parse_request(fmt.tprintf(`{{"op":"apply","action":"del","packages":["track"],"plan_id":"%s"}}`, id))
	check(why == "" && r.op == .Apply && r.plan_id == id, "apply parses: %s", why)

	refusals := [?][2]string {
		{`not json`, "not JSON"},
		{`[1,2]`, "not an object"},
		{`{}`, "no op"},
		{`{"op":"search","packages":["x"]}`, "a query op"},
		{`{"op":"plan","action":"fix","packages":["x"]}`, "an action outside the set"},
		{`{"op":"plan","action":"add"}`, "add with no packages"},
		{`{"op":"plan","action":"add","packages":[]}`, "add with an empty list"},
		{`{"op":"plan","action":"add","packages":"track"}`, "packages as a string"},
		{`{"op":"plan","action":"add","packages":[1]}`, "a number as a name"},
		{`{"op":"plan","action":"add","packages":["--root=/"]}`, "an option as a name"},
		{`{"op":"plan","action":"add","packages":["x;rm -rf /"]}`, "a shell command as a name"},
		{`{"op":"plan","action":"add","packages":["../../etc/shadow"]}`, "a path as a name"},
		{`{"op":"plan","action":"add","packages":["track"],"root":"/tmp"}`, "an extra field"},
		{`{"op":"plan","action":"add","packages":["track"],"args":["--allow-untrusted"]}`, "smuggled arguments"},
		{`{"op":"plan","action":"upgrade","packages":["track"]}`, "upgrade with packages"},
		{`{"op":"plan","action":"add","packages":["track"],"plan_id":"0123456789abcdef0123456789abcdef"}`, "plan with a plan_id"},
		{`{"op":"apply","action":"add","packages":["track"]}`, "apply without a plan_id"},
		{`{"op":"apply","action":"add","packages":["track"],"plan_id":"--yes"}`, "apply with a malformed plan_id"},
		{`{"op":"update","action":"add"}`, "update with fields"},
	}
	for c in refusals {
		_, w := parse_request(c[0])
		check(w != "", "%s is refused", c[1])
	}
	many := strings.builder_make(context.temp_allocator)
	strings.write_string(&many, `{"op":"plan","action":"add","packages":[`)
	for i in 0 ..= MAX_PACKAGES {
		if i > 0 {strings.write_byte(&many, ',')}
		fmt.sbprintf(&many, `"p%d"`, i)
	}
	strings.write_string(&many, "]}")
	_, why = parse_request(strings.to_string(many))
	check(why != "", "more than %d packages is refused", MAX_PACKAGES)
}

@(private = "file")
test_argv_and_ids :: proc() {
	section("palm's argv and plan ids")
	r, _ := parse_request(`{"op":"plan","action":"add","packages":["track","emoji"]}`)
	argv := palm_argv("/usr/bin/palm", r, true, context.temp_allocator)
	check(strings.join(argv, " ", context.temp_allocator) == "/usr/bin/palm add --json --dry-run track emoji", "plan argv: %v", argv)
	argv = palm_argv("/usr/bin/palm", r, false, context.temp_allocator)
	check(strings.join(argv, " ", context.temp_allocator) == "/usr/bin/palm add --json --yes track emoji", "apply argv: %v", argv)
	u, _ := parse_request(`{"op":"update"}`)
	argv = palm_argv("/usr/bin/palm", u, false, context.temp_allocator)
	check(strings.join(argv, " ", context.temp_allocator) == "/usr/bin/palm update --json", "update argv: %v", argv)
	up, _ := parse_request(`{"op":"plan","action":"upgrade"}`)
	argv = palm_argv("/usr/bin/palm", up, true, context.temp_allocator)
	check(strings.join(argv, " ", context.temp_allocator) == "/usr/bin/palm upgrade --json --dry-run", "upgrade argv: %v", argv)
	for a in argv[1:] {
		check(a == "upgrade" || a == "--json" || a == "--dry-run", "only constant words in an upgrade argv (%q)", a)
	}

	plan := `{"install":[{"name":"track","version":"0.1.0-r0"}],"remove":[],"dry_run":true}`
	id1 := plan_id_of(r, plan)
	check(plan_id_valid(id1), "a plan id is 32 hex digits: %s", id1)
	check(plan_id_of(r, plan) == id1, "the same plan has the same id")
	check(plan_id_of(r, fmt.tprintf("  %s\n", plan)) == id1, "surrounding whitespace does not change it")
	check(plan_id_of(r, strings.concatenate({plan[:len(plan) - 1], `,"x":1}`}, context.temp_allocator)) != id1, "a different plan has a different id")
	other, _ := parse_request(`{"op":"plan","action":"del","packages":["track","emoji"]}`)
	check(plan_id_of(other, plan) != id1, "a different action has a different id")

	msg, is := reply_progress(`{"event":"install","name":"track","version":"0.1.0-r0","step":2,"steps":2}`)
	check(is && strings.has_prefix(msg, `{"type":"progress","event":"install"`), "palm's progress is wrapped: %s", msg)
	_, is = reply_progress(`palm: warning: something`)
	check(!is, "prose is not progress")
	_, is = reply_progress(`{"event":"install"`)
	check(!is, "a truncated object is not progress")
	check(palm_error(`{"ok":false,"code":3,"error":"nosuch: no such package"}`, "", 3) == "nosuch: no such package", "palm's JSON error is passed verbatim")
	check(palm_error("", "palm: warning: x\nSegmentation fault\n", 139) == "Segmentation fault", "else the last stderr line")
	check(palm_document("{\"install\":[]}\n{\"ok\":false,\"code\":4,\"error\":\"x\"}\n") == `{"install":[]}`, "the document is the first object that is not an error")
}

@(private = "file")
test_framing :: proc() {
	section("framing")
	buf := make([dynamic]u8, context.temp_allocator)
	frame :: proc(buf: ^[dynamic]u8, s: string) {
		n := u32(len(s))
		hdr := transmute([4]u8)n
		append(buf, ..hdr[:])
		append(buf, ..transmute([]u8)s)
	}
	frame(&buf, `{"op":"update"}`)
	frame(&buf, `{"op":"plan"}`)
	half := buf[:len(buf) - 3]
	partial := make([dynamic]u8, context.temp_allocator)
	append(&partial, ..half[:])
	p1, ok1, bad1 := next_frame(&partial)
	check(ok1 && !bad1 && p1 == `{"op":"update"}`, "first frame: %q", p1)
	_, ok2, bad2 := next_frame(&partial)
	check(!ok2 && !bad2, "a partial frame waits for the rest")
	append(&partial, ..buf[len(buf) - 3:])
	p3, ok3, _ := next_frame(&partial)
	check(ok3 && p3 == `{"op":"plan"}`, "it completes when the rest arrives")
	check(len(partial) == 0, "nothing is left over")

	huge := make([dynamic]u8, context.temp_allocator)
	n := u32(MAX_FRAME + 1)
	hdr := transmute([4]u8)n
	append(&huge, ..hdr[:])
	_, _, bad := next_frame(&huge)
	check(bad, "a frame over %d bytes is refused", MAX_FRAME)
	zero := make([dynamic]u8, context.temp_allocator)
	append(&zero, 0, 0, 0, 0)
	_, _, badz := next_frame(&zero)
	check(badz, "an empty frame is refused")
}

PASSWD_FIXTURE :: `root:x:0:0:root:/root:/bin/sh
palm:x:1000:1000:Palm:/home/palm:/bin/sh
guest:x:1001:1001:Guest:/home/guest:/bin/sh
op:x:1002:10:Operator:/home/op:/bin/sh
greeter:x:900:900:Login greeter:/var/lib/greeter:/sbin/nologin
`

GROUP_FIXTURE :: `root:x:0:root
wheel:x:10:root,palm
video:x:39:palm,greeter,guest
palm:x:1000:
guest:x:1001:
`

@(private = "file")
test_authorize :: proc() {
	section("authorization")
	ok0, u0, _ := authorize(0, "", "")
	check(ok0 && u0 == "root", "uid 0 is always allowed, even with no files")
	ok1, u1, _ := authorize(1000, PASSWD_FIXTURE, GROUP_FIXTURE)
	check(ok1 && u1 == "palm", "palm is in wheel's member list")
	ok2, u2, why2 := authorize(1001, PASSWD_FIXTURE, GROUP_FIXTURE)
	check(!ok2 && u2 == "guest" && why2 != "", "guest is refused (%s)", why2)
	ok3, _, _ := authorize(1002, PASSWD_FIXTURE, GROUP_FIXTURE)
	check(ok3, "a user whose primary group is wheel is allowed")
	ok4, _, why4 := authorize(4242, PASSWD_FIXTURE, GROUP_FIXTURE)
	check(!ok4 && strings.contains(why4, "not in /etc/passwd"), "an unknown uid is refused")
	ok5, _, _ := authorize(900, PASSWD_FIXTURE, GROUP_FIXTURE)
	check(!ok5, "membership of another group (video) is not wheel")
	ok6, _, why6 := authorize(1000, PASSWD_FIXTURE, "root:x:0:root\n")
	check(!ok6 && strings.contains(why6, "no group wheel"), "no wheel group means root only")
	ok7, _, _ := authorize(1000, PASSWD_FIXTURE, "wheel:x:10:root, palm \n")
	check(ok7, "member lists tolerate spaces")
	ok8, _, _ := authorize(1000, PASSWD_FIXTURE, "wheel:x:10:root,palmer\n")
	check(!ok8, "a member is matched whole, not by prefix")
	ok9, _, _ := authorize(1000, PASSWD_FIXTURE, "# wheel:x:10:palm\nwheel:x:10:root\n")
	check(!ok9, "a commented-out line grants nothing")
}

@(private = "file")
test_peercred :: proc() {
	section("SO_PEERCRED")
	pair: [2]linux.Fd
	if e := linux.socketpair(.UNIX, .STREAM, .HOPOPT, &pair); e != .NONE {
		check(false, "socketpair: %v", e)
		return
	}
	defer {
		linux.close(pair[0])
		linux.close(pair[1])
	}
	p, ok := peer_cred(pair[0])
	check(ok, "SO_PEERCRED is answered")
	check(p.uid == u32(linux.getuid()), "the peer's uid is ours (%d)", p.uid)
	check(p.gid == u32(linux.getgid()), "the peer's gid is ours (%d)", p.gid)
	check(p.pid == i32(linux.getpid()), "the peer's pid is ours (%d)", p.pid)
}

// ---------------------------------------------------------------------------
// The daemon, end to end
// ---------------------------------------------------------------------------

// FAKE_PALM stands in for /usr/bin/palm. It appends its argv to a file, and
// answers as palm does under --json: the plan on stdout, progress on stderr.
// A package named "broken" fails the way palm fails; "slow" takes a second,
// long enough for a second client to find the daemon busy. FAKE_STATE, when
// it exists, changes the plan -- the repository moving under a confirmation.
FAKE_PALM :: `#!/bin/sh
dir=$(dirname "$0")
echo "$*" >> "$dir/argv.log"
verb=$1
shift
case "$verb" in
update)
	echo '{"repositories":[{"url":"http://10.0.2.2:8091/x86_64","packages":38,"signed_by":"palmy.pub"}]}'
	exit 0 ;;
esac
dry=no
names=
for a in "$@"; do
	case "$a" in
	--dry-run) dry=yes ;;
	--json|--yes) ;;
	*) names="$names $a" ;;
	esac
done
extra=
[ -f "$dir/state" ] && extra=',{"name":"surprise","version":"1-r0","size":1,"csize":1}'
for n in $names; do
	case "$n" in broken)
		echo '{"ok":false,"code":3,"error":"broken: no such package"}'
		exit 3 ;;
	esac
done
echo "{\"install\":[{\"name\":\"track\",\"version\":\"0.1.0-r0\",\"size\":100,\"csize\":50}$extra],\"upgrade\":[],\"remove\":[],\"download_size\":50,\"size_change\":100,\"dry_run\":$( [ $dry = yes ] && echo true || echo false )}"
[ $dry = yes ] && exit 0
case "$names" in *slow*) sleep 1 ;; esac
echo '{"event":"fetch","name":"track","version":"0.1.0-r0","step":1,"steps":2}' >&2
echo 'palm: warning: track expects the user "nobody"' >&2
echo '{"event":"install","name":"track","version":"0.1.0-r0","step":2,"steps":2}' >&2
exit 0
`

@(private = "file")
Client :: struct {
	fd:  linux.Fd,
	buf: [dynamic]u8,
}

@(private = "file")
dial :: proc(sock: string) -> (c: Client, ok: bool) {
	fd, e := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if e != .NONE {
		return c, false
	}
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]u8)sock)
	if linux.connect(fd, &addr) != .NONE {
		linux.close(fd)
		return c, false
	}
	c.fd = fd
	c.buf = make([dynamic]u8, context.temp_allocator)
	return c, true
}

// recv waits up to five seconds for the next reply; "" means none came.
@(private = "file")
recv :: proc(c: ^Client) -> string {
	deadline := time.tick_now()
	for time.tick_since(deadline) < 5 * time.Second {
		if p, got, _ := next_frame(&c.buf); got {
			return p
		}
		pfd := [1]linux.Poll_Fd{{fd = c.fd, events = {.IN}}}
		linux.poll(pfd[:], 200)
		if pfd[0].revents == {} {
			continue
		}
		chunk: [4096]u8
		n, e := linux.read(c.fd, chunk[:])
		if e != .NONE || n <= 0 {
			return ""
		}
		append(&c.buf, ..chunk[:n])
	}
	return ""
}

// until reads replies until one of the final kinds, returning all of them.
@(private = "file")
until_final :: proc(c: ^Client) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for _ in 0 ..< 64 {
		r := recv(c)
		if r == "" {break}
		append(&out, r)
		if strings.has_prefix(r, `{"type":"plan"`) || strings.has_prefix(r, `{"type":"result"`) || strings.has_prefix(r, `{"type":"error"`) {
			break
		}
	}
	return out[:]
}

@(private = "file")
field :: proc(reply, key: string) -> string {
	i := strings.index(reply, fmt.tprintf(`"%s":"`, key))
	if i < 0 {return ""}
	rest := reply[i + len(key) + 4:]
	j := strings.index_byte(rest, '"')
	return j < 0 ? "" : rest[:j]
}

@(private = "file")
test_daemon :: proc() {
	section("the daemon, against a fake palm")
	dir := fmt.tprintf("/tmp/palmd-selftest-%d", linux.getpid())
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	fake := fmt.tprintf("%s/palm", dir)
	_ = os.write_entire_file(fake, transmute([]u8)string(FAKE_PALM), os.perm_number(0o755))
	me := u32(linux.getuid())
	passwd := fmt.tprintf("%s/passwd", dir)
	group := fmt.tprintf("%s/group", dir)
	_ = os.write_entire_file(passwd, transmute([]u8)fmt.tprintf("root:x:0:0:root:/root:/bin/sh\ntester:x:%d:4242:Tester:/tmp:/bin/sh\n", me))
	_ = os.write_entire_file(group, transmute([]u8)string("wheel:x:10:root,tester\n"))
	sock := fmt.tprintf("%s/palmd.sock", dir)
	log := fmt.tprintf("%s/palmd.log", dir)

	self, _ := os.get_executable_path(context.temp_allocator)
	p, perr := os.process_start(os.Process_Desc{command = {self, "--test", "--sock", sock, "--palm", fake, "--passwd", passwd, "--group", group, "--log", log}})
	if perr != nil {
		check(false, "the daemon starts: %v", perr)
		return
	}
	defer {
		_ = os.process_kill(p)
		_, _ = os.process_wait(p)
	}
	for _ in 0 ..< 50 {
		if os.exists(sock) {break}
		time.sleep(20 * time.Millisecond)
	}
	st: linux.Stat
	linux.stat(strings.clone_to_cstring(sock, context.temp_allocator), &st)
	mode := transmute(u32)st.mode & 0o777
	check(mode == 0o666, "the socket is 0666 (%o)", mode)

	c, ok := dial(sock)
	check(ok, "a wheel member connects")
	if !ok {return}
	defer linux.close(c.fd)

	// plan
	send_frame(c.fd, `{"op":"plan","action":"add","packages":["track"]}`)
	r := until_final(&c)
	check(len(r) == 1 && strings.has_prefix(r[0], `{"type":"plan"`), "plan answers with a plan: %v", r)
	id := len(r) > 0 ? field(r[0], "plan_id") : ""
	check(plan_id_valid(id), "the plan has an id: %q", id)
	check(len(r) > 0 && strings.contains(r[0], `"download_size":50`), "palm's plan is passed through whole")

	// apply with the wrong id: refused without running palm for real
	wrong := strings.repeat("0", 32, context.temp_allocator)
	send_frame(c.fd, fmt.tprintf(`{{"op":"apply","action":"add","packages":["track"],"plan_id":"%s"}}`, wrong))
	r = until_final(&c)
	last := len(r) > 0 ? r[len(r) - 1] : ""
	check(strings.has_prefix(last, `{"type":"result","ok":false,"code":4`) && strings.contains(last, "plan has changed"), "a stale plan id is refused: %s", last)

	// apply with the right id: progress, a log line, then the result
	send_frame(c.fd, fmt.tprintf(`{{"op":"apply","action":"add","packages":["track"],"plan_id":"%s"}}`, id))
	r = until_final(&c)
	kinds := strings.builder_make(context.temp_allocator)
	for x in r {
		fmt.sbprintf(&kinds, "%s ", x[9:min(len(x), 17)])
	}
	check(len(r) == 4, "apply streams fetch, log, install, result: %s", strings.to_string(kinds))
	check(len(r) == 4 && strings.has_prefix(r[0], `{"type":"progress","event":"fetch"`), "first, palm's fetch")
	check(len(r) == 4 && strings.has_prefix(r[1], `{"type":"log"`) && strings.contains(r[1], `expects the user`), "a warning arrives as a log line")
	check(len(r) == 4 && strings.contains(r[2], `"step":2,"steps":2`), "the install step carries its position")
	check(len(r) == 4 && strings.has_prefix(r[3], `{"type":"result","ok":true,"code":0`) && strings.contains(r[3], `"plan":{"install"`), "then the result, with the plan that ran")

	// the plan changes between plan and apply
	send_frame(c.fd, `{"op":"plan","action":"add","packages":["track"]}`)
	r = until_final(&c)
	id2 := len(r) > 0 ? field(r[0], "plan_id") : ""
	check(id2 == id, "the same request plans to the same id")
	_ = os.write_entire_file(fmt.tprintf("%s/state", dir), nil)
	send_frame(c.fd, fmt.tprintf(`{{"op":"apply","action":"add","packages":["track"],"plan_id":"%s"}}`, id2))
	r = until_final(&c)
	last = len(r) > 0 ? r[len(r) - 1] : ""
	check(strings.contains(last, `"ok":false`) && strings.contains(last, "surprise"), "a plan that changed is refused and the new plan shown: %s", last)
	_ = os.remove(fmt.tprintf("%s/state", dir))

	// palm's own error, verbatim
	send_frame(c.fd, `{"op":"plan","action":"add","packages":["broken"]}`)
	r = until_final(&c)
	last = len(r) > 0 ? r[len(r) - 1] : ""
	check(strings.contains(last, `"code":3`) && strings.contains(last, `"error":"broken: no such package"`), "palm's error reaches the client verbatim: %s", last)

	// malicious requests never reach palm
	send_frame(c.fd, `{"op":"plan","action":"add","packages":["--root=/"]}`)
	r = until_final(&c)
	check(len(r) == 1 && strings.has_prefix(r[0], `{"type":"error","error_type":"invalid"`), "--root=/ is refused: %v", r)
	send_frame(c.fd, `{"op":"plan","action":"add","packages":["x;rm"]}`)
	r = until_final(&c)
	check(len(r) == 1 && strings.has_prefix(r[0], `{"type":"error","error_type":"invalid"`), "x;rm is refused: %v", r)

	// update
	send_frame(c.fd, `{"op":"update"}`)
	r = until_final(&c)
	last = len(r) > 0 ? r[len(r) - 1] : ""
	check(strings.has_prefix(last, `{"type":"result","ok":true`) && strings.contains(last, `"update":{"repositories"`), "update returns palm's repository list: %s", last)

	// busy: one apply at a time
	send_frame(c.fd, `{"op":"plan","action":"add","packages":["slow"]}`)
	r = until_final(&c)
	sid := len(r) > 0 ? field(r[0], "plan_id") : ""
	send_frame(c.fd, fmt.tprintf(`{{"op":"apply","action":"add","packages":["slow"],"plan_id":"%s"}}`, sid))
	time.sleep(300 * time.Millisecond)
	c2, ok2 := dial(sock)
	if ok2 {
		send_frame(c2.fd, `{"op":"plan","action":"del","packages":["track"]}`)
		r2 := until_final(&c2)
		check(len(r2) == 1 && strings.contains(r2[0], `"error_type":"busy"`), "a second client is told the daemon is busy: %v", r2)
		linux.close(c2.fd)
	}
	r = until_final(&c)
	last = len(r) > 0 ? r[len(r) - 1] : ""
	check(strings.has_prefix(last, `{"type":"result","ok":true`), "the slow apply still finishes: %s", last)

	// what palm was actually run with
	argv_log := read_text(fmt.tprintf("%s/argv.log", dir))
	check(!strings.contains(argv_log, "--root") && !strings.contains(argv_log, ";"), "nothing malicious reached palm's argv")
	check(strings.contains(argv_log, "add --json --dry-run track\n") && strings.contains(argv_log, "add --json --yes track\n"), "palm ran with the argv palmd built:\n%s", argv_log)
	check(strings.count(argv_log, "--yes track\n") == 1, "the refused applies never ran palm for real")

	// a user removed from wheel is turned away at the next connection
	_ = os.write_entire_file(group, transmute([]u8)string("wheel:x:10:root\n"))
	c3, ok3 := dial(sock)
	if ok3 {
		send_frame(c3.fd, `{"op":"update"}`)
		r3 := until_final(&c3)
		check(len(r3) == 1 && strings.contains(r3[0], `"error_type":"denied"`), "a non-wheel user is refused: %v", r3)
		linux.close(c3.fd)
	}

	logged := read_text(log)
	check(!strings.contains(logged, "scheduled refresh"), "--test schedules no refresh unless asked")
	check(strings.contains(logged, fmt.tprintf("uid=%d (tester)", me)), "requests are logged with the peer's uid")
	check(strings.contains(logged, "refused") && strings.contains(logged, "--root=/"), "refusals are logged with what was asked")
	check(strings.contains(logged, fmt.tprintf("uid=%d (tester) pid=", me)) && strings.contains(logged, "only root and members of group wheel"), "the denied connection is logged")

	// The scheduled refresh: a daemon told to refresh every second runs
	// `palm update --json` by itself and logs the outcome.
	_ = os.remove(fmt.tprintf("%s/argv.log", dir))
	sock2 := fmt.tprintf("%s/palmd2.sock", dir)
	log2 := fmt.tprintf("%s/palmd2.log", dir)
	p2, perr2 := os.process_start(os.Process_Desc{command = {self, "--test", "--sock", sock2, "--palm", fake, "--passwd", passwd, "--group", group, "--log", log2, "--refresh-every", "1"}})
	if perr2 != nil {
		check(false, "the second daemon starts: %v", perr2)
		return
	}
	refreshed := false
	for _ in 0 ..< 60 {
		if strings.contains(read_text(log2), "palmd (scheduled refresh): update: done") {
			refreshed = true
			break
		}
		time.sleep(100 * time.Millisecond)
	}
	_ = os.process_kill(p2)
	_, _ = os.process_wait(p2)
	check(refreshed, "a scheduled refresh ran and was logged:\n%s", read_text(log2))
	check(strings.contains(read_text(fmt.tprintf("%s/argv.log", dir)), "update --json\n"), "as palm update --json")
}
