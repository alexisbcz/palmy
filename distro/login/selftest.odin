package login

// `palm-login --selftest`: everything that can be checked without root.
//
//	1. SHA-512 crypt against the test vectors in Drepper's specification
//	   (every one of them is also what `openssl passwd -6` prints), plus
//	   hashes made with openssl for the Palmy accounts.
//	2. The passwd, shadow and group parsers, on fixtures.
//	3. An IPC round trip: palm-login is started again in --test mode on a
//	   temporary socket with fixture account files, and this process plays the
//	   greeter — the right password, a wrong one, a locked account, an unknown
//	   one, requests out of order, a cancel, and a malformed frame.
//
// No session is started and nothing outside a temporary directory is touched.

import "auth"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

@(private = "file")
failures: int
@(private = "file")
checks: int

@(private = "file")
check :: proc(name: string, ok: bool, detail := "") {
	checks += 1
	if !ok {
		failures += 1
	}
	fmt.printfln("%s  %-58s %s", ok ? "pass" : "FAIL", name, detail)
}

// Drepper's vectors: salt/rounds setting, key, expected hash.
@(private = "file")
VECTORS := [?][3]string {
	{"$6$saltstring", "Hello world!", "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1"},
	{"$6$rounds=10000$saltstringsaltstring", "Hello world!", "$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v."},
	{"$6$rounds=5000$toolongsaltstring", "This is just a test", "$6$rounds=5000$toolongsaltstrin$lQ8jolhgVRVhY4b5pZKaysCLi0QBxGoNeKQzQ3glMhwllF7oGDZxUhx1yxdYcz/e1JSbq3y6JMxxl8audkUEm0"},
	{"$6$rounds=1400$anotherlongsaltstring", "a very much longer text to encrypt.  This one even stretches over morethan one line.", "$6$rounds=1400$anotherlongsalts$POfYwTEok97VWcjxIiSOjiykti.o/pQs.wPvMxQ6Fm7I6IoYN3CmLs66x9t0oSwbtEW7o7UmJEiDwGqd8p4ur1"},
	{"$6$rounds=77777$short", "we have a short salt string but not a short password", "$6$rounds=77777$short$WuQyW2YR.hBNpjjRhpYD/ifIw05xdfeEyQoMxIXbkvr0gge1a1x3yRULJ5CCaUeOxFmtlcGZelFl5CxtgfiAc0"},
	{"$6$rounds=123456$asaltof16chars..", "a short string", "$6$rounds=123456$asaltof16chars..$BtCwjqMJGx5hrJhZywWvt0RLE8uZ4oPwcelCjmw2kSYu.Ec6ycULevoBK25fs2xXgMNrCzIMVcgEJAstJeonj1"},
	{"$6$rounds=10$roundstoolow", "the minimum number is still observed", "$6$rounds=1000$roundstoolow$kUMsbe306n21p9R.FRkW3IGn.S9NPN0x50YhH1xhLsPuWGsUSklZt58jaTfF4ZEQpyUNGc0dqbpBYYBaHHrsX."},
	// openssl passwd -6 -salt palmy palm
	{"$6$palmy", "palm", HASH_PALM},
	// openssl passwd -6 -salt 'rounds=6000$rootsalt' palm
	{"$6$rounds=6000$rootsalt", "palm", HASH_ROOT},
	// openssl passwd -6 -salt p4lm 'pässwörd "quoted" \ back' — UTF-8 and JSON metacharacters
	{"$6$p4lm", `pässwörd "quoted" \ back`, HASH_ODD},
}

HASH_PALM :: "$6$palmy$Bx42s72Foe9Q131t36Vl6afUo26skw/rGH.Gh2.1sxjLqcF/K29Hy0bvYDGyHaLynMyqorU41mNCDjhXf2q.T."
HASH_ROOT :: "$6$rounds=6000$rootsalt$8MoobbtPehhfCz42EYUwppGiS8GThp9yQ9i9OoQGVpSVnQ.Hjpq.FgkddGDp8WFV13Nt0rQGlAf0SW7Iegu8y."
HASH_ODD :: "$6$p4lm$tHJ1rMp6XDpVJGykSeliFHpOuDxKz9sDaghmF/1FmYbdn1O9hW.10/Bd8F/LfuDj.zlRfWcvmnfQNs2F3O/RK/"

FIXTURE_PASSWD :: `# fixture
root:x:0:0:root:/root:/bin/sh
palm:x:1000:1000:Palm User,,,:/home/palm:/bin/sh
greeter:x:900:900:Greeter:/var/lib/greeter:/sbin/nologin
odd:x:1001:1001::/home/odd:/bin/sh
legacy:` + HASH_PALM + `:1002:1002::/home/legacy:/bin/sh
broken:x:notanumber:1003::/:/bin/sh
expiredpw:x:1004:1004::/home/e:/bin/sh
warnme:x:1005:1005::/home/w:/bin/sh
gone:x:1006:1006::/home/g:/bin/sh
limited:x:1007:1007::/home/l:/bin/sh
`

FIXTURE_SHADOW :: "root:" + HASH_ROOT + ":19000:0:99999:7:::\n" +
	"palm:" + HASH_PALM + ":19000:0:99999:7:::\n" +
	"greeter:!:19000::::::\n" +
	"odd:" + HASH_ODD + ":19000::::::\n" +
	"lockedpalm:!" + HASH_PALM + ":19000::::::\n"

FIXTURE_GROUP :: `root:x:0:
tty:x:5:
wheel:x:10:palm
audio:x:63:palm
video:x:39:palm,greeter
input:x:97:greeter, palm
greeter:x:900:
palm:x:1000:
`

selftest :: proc() -> int {
	fmt.println("palm-login selftest")
	fmt.println(strings.repeat("-", 78, context.temp_allocator))

	// --- 1. crypt -----------------------------------------------------------
	for v in VECTORS {
		got, ok := auth.sha512_crypt(v[1], v[0], context.temp_allocator)
		check(fmt.tprintf("crypt %s", v[0]), ok && got == v[2], ok && got != v[2] ? got : "")
	}
	check("crypt: verify accepts the right password", auth.verify_password("palm", HASH_PALM))
	check("crypt: verify refuses a wrong password", !auth.verify_password("Palm", HASH_PALM))
	check("crypt: verify refuses a locked hash", !auth.verify_password("palm", "!" + HASH_PALM))
	check("crypt: verify refuses '*' and empty", !auth.verify_password("", "*") && !auth.verify_password("", ""))
	check("crypt: verify refuses non-$6$ schemes", !auth.verify_password("palm", "$1$abc$def"))
	_, bad := auth.sha512_crypt("x", "$5$salt")
	check("crypt: a $5$ setting is not taken for $6$", !bad)

	// --- 2. parsers ---------------------------------------------------------
	{
		a, found := auth.parse_passwd(FIXTURE_PASSWD, "palm")
		check(
			"passwd: palm",
			found && a.uid == 1000 && a.gid == 1000 && a.home == "/home/palm" && a.shell == "/bin/sh" && a.passwd == "x",
			fmt.tprintf("%v", a),
		)
		_, nf := auth.parse_passwd(FIXTURE_PASSWD, "pal")
		check("passwd: a prefix of a name is not the name", !nf)
		_, br := auth.parse_passwd(FIXTURE_PASSWD, "broken")
		check("passwd: a malformed uid is refused", !br)
		_, cm := auth.parse_passwd(FIXTURE_PASSWD, "# fixture")
		check("passwd: comments are skipped", !cm)

		h, hf := auth.parse_shadow(FIXTURE_SHADOW, "greeter")
		check("shadow: greeter is locked", hf && h == "!", h)
		h2, _ := auth.parse_shadow(FIXTURE_SHADOW, "root")
		check("shadow: root's hash", h2 == HASH_ROOT)

		g := auth.parse_groups(FIXTURE_GROUP, "palm", 1000, context.temp_allocator)
		check(
			"group: palm is in palm, wheel, audio, video, input",
			len(g) == 5 && g[0] == 1000 && slice_has(g, 10) && slice_has(g, 63) && slice_has(g, 39) && slice_has(g, 97),
			fmt.tprintf("%v", g),
		)
		gg := auth.parse_groups(FIXTURE_GROUP, "greeter", 900, context.temp_allocator)
		check("group: greeter is in greeter, video, input", len(gg) == 3, fmt.tprintf("%v", gg))
		gid, gok := auth.group_id(FIXTURE_GROUP, "greeter")
		check("group: greeter's gid", gok && gid == 900)

		env := base_env(a, context.temp_allocator)
		merge_env(&env, {"XDG_CURRENT_DESKTOP=Other", "EXTRA=1", "bogus"}, context.temp_allocator)
		joined := strings.join(env[:], " ", context.temp_allocator)
		check(
			"session env: contract keys, request env wins, no duplicates",
			strings.contains(joined, "HOME=/home/palm") &&
			strings.contains(joined, "XDG_RUNTIME_DIR=/run/user/1000") &&
			strings.contains(joined, "XDG_SESSION_TYPE=wayland") &&
			strings.contains(joined, "XDG_CURRENT_DESKTOP=Other") &&
			!strings.contains(joined, "XDG_CURRENT_DESKTOP=palmy") &&
			strings.contains(joined, "EXTRA=1") &&
			!strings.contains(joined, "bogus"),
			joined,
		)
	}

	// --- 2b. language and time zone (locale.odin) --------------------------
	{
		got := parse_locale_conf(`# written by palm-install
LANG="fr_FR.UTF-8"
LANGUAGE=fr:en
export LC_TIME='de_DE.UTF-8'
PATH=/tmp/evil
LD_PRELOAD=/tmp/x.so
LC_PAPER=has space
LANG=fr_CA.UTF-8
`, context.temp_allocator)
		joined := strings.join(got, " ", context.temp_allocator)
		check(
			"locale.conf: LANG (last wins), LANGUAGE, LC_*, quotes stripped",
			len(got) == 3 && got[0] == "LANG=fr_CA.UTF-8" && got[1] == "LANGUAGE=fr:en" && got[2] == "LC_TIME=de_DE.UTF-8",
			joined,
		)
		check(
			"locale.conf: unknown keys and odd values are not exported",
			!strings.contains(joined, "PATH") && !strings.contains(joined, "LD_PRELOAD") && !strings.contains(joined, "LC_PAPER"),
			joined,
		)
		check("timezone: a zone name", parse_timezone_file("Europe/Paris\n") == "Europe/Paris")
		check(
			"timezone: paths and junk are refused",
			parse_timezone_file("/etc/passwd") == "" && parse_timezone_file("../../x") == "" && parse_timezone_file("a b") == "",
		)

		dir := fmt.tprintf("/tmp/palm-login-selftest-%d", linux.getpid())
		os.make_directory(dir)
		conf := fmt.tprintf("%s/locale.conf", dir)
		tzf := fmt.tprintf("%s/timezone", dir)
		ltf := fmt.tprintf("%s/localtime", dir)
		_ = os.write_entire_file(conf, transmute([]u8)string("LANG=ar_EG.UTF-8\n"))
		_ = os.write_entire_file(tzf, transmute([]u8)string("Africa/Cairo\n"))
		paths := Paths{locale_conf = conf, timezone = tzf, localtime = ltf}

		e := system_locale_env(paths, context.temp_allocator)
		check(
			"session env: LANG from locale.conf, TZ from /etc/timezone when localtime is missing",
			len(e) == 2 && e[0] == "LANG=ar_EG.UTF-8" && e[1] == "TZ=Africa/Cairo",
			strings.join(e, " ", context.temp_allocator),
		)
		_ = os.write_entire_file(ltf, transmute([]u8)string("TZif"))
		e = system_locale_env(paths, context.temp_allocator)
		check("session env: no TZ once localtime exists", len(e) == 1 && e[0] == "LANG=ar_EG.UTF-8", strings.join(e, " ", context.temp_allocator))

		a, _ := auth.parse_passwd(FIXTURE_PASSWD, "greeter")
		env := base_env(a, context.temp_allocator)
		merge_env(&env, e, context.temp_allocator)
		merge_env(&env, {"GREETD_SOCK=/run/palm-login.sock"}, context.temp_allocator)
		joined = strings.join(env[:], " ", context.temp_allocator)
		check(
			"session env: locale.conf's LANG replaces the C.UTF-8 default",
			strings.contains(joined, "LANG=ar_EG.UTF-8") && !strings.contains(joined, "LANG=C.UTF-8"),
			joined,
		)
		e = system_locale_env(Paths{locale_conf = fmt.tprintf("%s/missing", dir)}, context.temp_allocator)
		check("session env: no locale.conf exports nothing", len(e) == 0)

		os.remove(conf)
		os.remove(tzf)
		os.remove(ltf)

		// session.d: executables only, in name order, no hidden files or
		// editor leftovers, and a missing directory is no hooks.
		hd := fmt.tprintf("%s/session.d", dir)
		os.make_directory(hd)
		mk :: proc(dir, name: string, exec: bool) {
			p := fmt.tprintf("%s/%s", dir, name)
			_ = os.write_entire_file(p, transmute([]u8)string("#!/bin/sh\n"))
			linux.chmod(fmt.ctprintf("%s", p), exec ? {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH} : {.IRUSR, .IWUSR})
		}
		mk(hd, "50-pipewire", true)
		mk(hd, "10-first", true)
		mk(hd, "20-not-executable", false)
		mk(hd, ".hidden", true)
		mk(hd, "30-old~", true)
		mk(hd, "40-x.new", true)
		os.make_directory(fmt.tprintf("%s/60-dir", hd))
		hooks := session_hooks(hd, context.temp_allocator)
		check(
			"session.d: executables in name order, nothing else",
			len(hooks) == 2 && hooks[0] == fmt.tprintf("%s/10-first", hd) && hooks[1] == fmt.tprintf("%s/50-pipewire", hd),
			fmt.tprintf("%v", hooks),
		)
		check("session.d: a missing directory is no hooks", len(session_hooks(fmt.tprintf("%s/none", dir), context.temp_allocator)) == 0)
		for n in ([]string{"50-pipewire", "10-first", "20-not-executable", ".hidden", "30-old~", "40-x.new", "60-dir"}) {
			os.remove(fmt.tprintf("%s/%s", hd, n))
		}
		os.remove(hd)
		os.remove(dir)
	}

	// --- 3. IPC round trip --------------------------------------------------
	ipc_round_trip()

	// --- 4. the session socket ----------------------------------------------
	session_socket_tests()

	fmt.println(strings.repeat("-", 78, context.temp_allocator))
	fmt.printfln("%d checks, %d failed", checks, failures)
	return failures == 0 ? 0 : 1
}

@(private = "file")
slice_has :: proc(s: []u32, v: u32) -> bool {
	for x in s {
		if x == v {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// The client half, as small as it can be
// ---------------------------------------------------------------------------

@(private = "file")
Reply :: struct {
	type:        string,
	error_type:  string,
	description: string,
	auth_type:   string,
	message:     string,
}

@(private = "file")
dial :: proc(path: string) -> (linux.Fd, bool) {
	fd, e := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if e != .NONE {
		return -1, false
	}
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]u8)path)
	if linux.connect(fd, &addr) != .NONE {
		linux.close(fd)
		return -1, false
	}
	return fd, true
}

@(private = "file")
read_exact :: proc(fd: linux.Fd, buf: []u8) -> bool {
	off := 0
	for off < len(buf) {
		fds := [1]linux.Poll_Fd{{fd = fd, events = {.IN}}}
		n, _ := linux.poll(fds[:], 5000)
		if n <= 0 {
			return false
		}
		r, e := linux.read(fd, buf[off:])
		if e != .NONE || r <= 0 {
			return false
		}
		off += r
	}
	return true
}

// ask sends one request and reads one reply. A closed connection comes back
// as type "closed".
@(private = "file")
ask :: proc(fd: linux.Fd, payload: string) -> Reply {
	if !send_frame(fd, payload) {
		return {type = "closed"}
	}
	return answer(fd)
}

@(private = "file")
answer :: proc(fd: linux.Fd) -> Reply {
	hdr: [4]u8
	if !read_exact(fd, hdr[:]) {
		return {type = "closed"}
	}
	n := int(transmute(u32)hdr)
	if n <= 0 || n > MAX_FRAME {
		return {type = "bad-length"}
	}
	buf := make([]u8, n, context.temp_allocator)
	if !read_exact(fd, buf) {
		return {type = "closed"}
	}
	v, err := json.parse(buf, .JSON, true, context.temp_allocator)
	if err != nil {
		return {type = "bad-json"}
	}
	obj, _ := v.(json.Object)
	get :: proc(obj: json.Object, k: string) -> string {
		if s, ok := obj[k].(json.String); ok {
			return string(s)
		}
		return ""
	}
	return {
		type = get(obj, "type"),
		error_type = get(obj, "error_type"),
		description = get(obj, "description"),
		auth_type = get(obj, "auth_message_type"),
		message = get(obj, "auth_message"),
	}
}

@(private = "file")
create :: proc(user: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"type":"create_session","username":`)
	json_quote(&sb, user)
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

@(private = "file")
respond :: proc(pw: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"type":"post_auth_message_response","response":`)
	json_quote(&sb, pw)
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

START :: `{"type":"start_session","cmd":["wm","--drm"],"env":["XDG_SESSION_TYPE=wayland"]}`
CANCEL :: `{"type":"cancel_session"}`

// login runs create → password and returns the final reply.
@(private = "file")
login :: proc(fd: linux.Fd, user, pw: string) -> (asked: Reply, final: Reply) {
	asked = ask(fd, create(user))
	if asked.type != "auth_message" {
		return asked, asked
	}
	return asked, ask(fd, respond(pw))
}

@(private = "file")
ipc_round_trip :: proc() {
	dir := fmt.tprintf("/tmp/palm-login-selftest-%d", linux.getpid())
	os.make_directory(dir, os.perm(0o700))
	defer os.remove_all(dir)

	write :: proc(path, text: string) {
		_ = os.write_entire_file(path, transmute([]u8)text)
	}
	passwd := fmt.tprintf("%s/passwd", dir)
	shadow := fmt.tprintf("%s/shadow", dir)
	group := fmt.tprintf("%s/group", dir)
	sock := fmt.tprintf("%s/sock", dir)
	logp := fmt.tprintf("%s/daemon.log", dir)
	write(passwd, FIXTURE_PASSWD)
	// The aging fixtures are relative to today.
	day := auth.today()
	write(
		shadow,
		fmt.tprintf(
			"%sexpiredpw:%s:0:0:99999:7:::\nwarnme:%s:%d:0:100:7:::\ngone:%s:19000:::::1:\nlimited:%s:19000::::::\n",
			FIXTURE_SHADOW,
			HASH_PALM,
			HASH_PALM,
			day - 95,
			HASH_PALM,
			HASH_PALM,
		),
	)
	write(group, FIXTURE_GROUP)

	// The daemon under test is this same binary in --test mode.
	argv := []cstring {
		"palm-login",
		"--test",
		"--sock",
		strings.clone_to_cstring(sock, context.temp_allocator),
		"--passwd",
		strings.clone_to_cstring(passwd, context.temp_allocator),
		"--shadow",
		strings.clone_to_cstring(shadow, context.temp_allocator),
		"--group",
		strings.clone_to_cstring(group, context.temp_allocator),
		nil,
	}
	envp := []cstring{nil}
	logfd, _ := linux.open(
		strings.clone_to_cstring(logp, context.temp_allocator),
		{.WRONLY, .CREAT, .TRUNC},
		{.IRUSR, .IWUSR},
	)
	pid, fe := linux.fork()
	if fe != .NONE {
		check("ipc: fork the daemon", false, fmt.tprintf("%v", fe))
		return
	}
	if pid == 0 {
		linux.dup2(logfd, 1)
		linux.dup2(logfd, 2)
		linux.execve("/proc/self/exe", raw_data(argv), raw_data(envp))
		linux.exit(127)
	}
	linux.close(logfd)
	defer {
		linux.kill(pid, .SIGTERM)
		status: u32
		linux.wait4(pid, &status, {}, nil)
		if failures > 0 {
			if data, err := os.read_entire_file_from_path(logp, context.temp_allocator); err == nil {
				fmt.printfln("--- daemon log ---\n%s------------------", string(data))
			}
		}
	}

	fd: linux.Fd
	up := false
	for _ in 0 ..< 100 {
		if f, ok := dial(sock); ok {
			fd, up = f, true
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	check("ipc: the --test daemon listens", up, sock)
	if !up {
		return
	}

	// The happy path, then start_session, on one connection.
	{
		asked, final := login(fd, "palm", "palm")
		check(
			"ipc: create_session asks a secret question",
			asked.type == "auth_message" && asked.auth_type == "secret",
			fmt.tprintf("%v %q", asked.auth_type, asked.message),
		)
		check("ipc: the right password is success", final.type == "success", final.description)
		r := ask(fd, START)
		check("ipc: start_session after auth is success", r.type == "success", r.description)
		r = ask(fd, START)
		check(
			"ipc: a second start_session without auth is an error",
			r.type == "error" && r.error_type == "error",
			r.description,
		)
	}

	// A wrong password, on the same connection, then the right one: an
	// auth_error leaves the connection usable.
	{
		t0 := time.tick_now()
		_, final := login(fd, "palm", "wrong")
		took := time.tick_since(t0)
		check(
			"ipc: a wrong password is auth_error",
			final.type == "error" && final.error_type == "auth_error",
			fmt.tprintf("%s %s", final.error_type, final.description),
		)
		check("ipc: the failure is answered late", took >= 140 * time.Millisecond, fmt.tprintf("%v", took))
		_, again := login(fd, "palm", "palm")
		check("ipc: the next attempt on the same connection works", again.type == "success", again.description)
		ask(fd, CANCEL)
	}

	// Accounts that must never get in, all answered identically.
	{
		_, l := login(fd, "greeter", "")
		check("ipc: the locked greeter account is refused", l.error_type == "auth_error", l.description)
		_, lp := login(fd, "lockedpalm", "palm")
		check("ipc: a '!'-locked hash is refused", lp.error_type == "auth_error", lp.description)
		asked, u := login(fd, "nobody-here", "palm")
		check(
			"ipc: an unknown user is asked and refused like any other",
			asked.auth_type == "secret" && u.error_type == "auth_error" && u.description == l.description,
			u.description,
		)
		_, b := login(fd, "broken", "palm")
		check("ipc: a malformed passwd line is refused", b.error_type == "auth_error", b.description)
	}

	// Other accounts and encodings.
	{
		_, r := login(fd, "root", "palm")
		check("ipc: root with a rounds= hash", r.type == "success", r.description)
		ask(fd, CANCEL)
		_, o := login(fd, "odd", `pässwörd "quoted" \ back`)
		check("ipc: UTF-8 and JSON escapes survive the wire", o.type == "success", o.description)
		ask(fd, CANCEL)
		_, lg := login(fd, "legacy", "palm")
		check("ipc: a hash kept in passwd itself", lg.type == "success", lg.description)
		ask(fd, CANCEL)
	}

	// Order.
	{
		r := ask(fd, respond("palm"))
		check("ipc: an answer with no question is an error", r.type == "error" && r.error_type == "error", r.description)
		ask(fd, create("palm"))
		r = ask(fd, create("palm"))
		check("ipc: a second create_session is an error", r.type == "error", r.description)
		r = ask(fd, START)
		check("ipc: start_session before the password is an error", r.type == "error", r.description)
		r = ask(fd, CANCEL)
		check("ipc: cancel_session is success", r.type == "success")
		r = ask(fd, respond("palm"))
		check("ipc: answering after a cancel is an error", r.type == "error" && r.error_type == "error", r.description)
		login(fd, "palm", "palm")
		r = ask(fd, `{"type":"start_session","cmd":"wm"}`)
		check("ipc: a start_session whose cmd is not a list is an error", r.type == "error", r.description)
		r = ask(fd, `{"type":"start_session","cmd":["wm"],"env":["NOEQUALS"]}`)
		check("ipc: an env entry without '=' is an error", r.type == "error", r.description)
		ask(fd, CANCEL)
		r = ask(fd, `{"type":"power","action":"reboot"}`)
		check("ipc: power{reboot} is accepted (test mode runs nothing)", r.type == "success", r.description)
		r = ask(fd, `{"type":"power","action":"rm -rf"}`)
		check("ipc: an unknown power action is an error", r.type == "error", r.description)
		r = ask(fd, `{"type":"reticulate_splines"}`)
		check("ipc: an unknown request is an error", r.type == "error", r.description)
	}

	// Shadow aging: an expired password is changed in the conversation, a
	// soon-expiring one is announced, an expired account is refused.
	{
		_, r := login(fd, "gone", "palm")
		check(
			"aging: an expired account is refused, saying why",
			r.error_type == "auth_error" && strings.contains(r.description, "expired"),
			r.description,
		)
		_, w := login(fd, "warnme", "palm")
		check(
			"aging: a password about to expire is an info message",
			w.type == "auth_message" && w.auth_type == "info" && strings.contains(w.message, "5 days"),
			fmt.tprintf("%s %s %q", w.type, w.auth_type, w.message),
		)
		ack := ask(fd, `{"type":"post_auth_message_response"}`)
		check("aging: ...acknowledged, then success", ack.type == "success", ack.description)
		ask(fd, CANCEL)

		_, e := login(fd, "expiredpw", "palm")
		check(
			"aging: an expired password asks for a new one",
			e.type == "auth_message" && e.auth_type == "secret" && strings.contains(e.message, "New password"),
			fmt.tprintf("%s %q", e.type, e.message),
		)
		short := ask(fd, respond("abc"))
		check("aging: a too-short password is an error message", short.type == "auth_message" && short.auth_type == "error", short.message)
		again := ask(fd, `{"type":"post_auth_message_response"}`)
		check("aging: ...then the question again", again.type == "auth_message" && again.auth_type == "secret", again.message)
		same := ask(fd, respond("palm"))
		check("aging: the old password is refused as the new one", same.auth_type == "error", same.message)
		ask(fd, `{"type":"post_auth_message_response"}`)
		ask(fd, respond("new-secret-1"))
		mism := ask(fd, respond("new-secret-2"))
		check("aging: a mismatched retype is an error message", mism.auth_type == "error" && strings.contains(mism.message, "match"), mism.message)
		ask(fd, `{"type":"post_auth_message_response"}`)
		retype := ask(fd, respond("new-secret-1"))
		check("aging: the retype question", retype.auth_type == "secret" && strings.contains(retype.message, "Retype"), retype.message)
		done := ask(fd, respond("new-secret-1"))
		check("aging: a matching retype changes the password and authenticates", done.type == "success", done.description)
		ask(fd, CANCEL)

		text, _ := auth.read_text(shadow)
		s, found, valid := auth.parse_shadow_entry(text, "expiredpw")
		check(
			"aging: shadow has the new hash and today's date",
			found && valid && s.lastchg == day && auth.verify_password("new-secret-1", s.hash),
			fmt.tprintf("%v", s),
		)
		p, _, _ := auth.parse_shadow_entry(text, "palm")
		check("aging: other lines are untouched", p.hash == HASH_PALM && p.lastchg == 19000 && p.max == 99999)
		_, old := login(fd, "expiredpw", "palm")
		check("aging: the old password no longer works", old.error_type == "auth_error", old.description)
		_, nw := login(fd, "expiredpw", "new-secret-1")
		check("aging: the new one does, with nothing more to ask", nw.type == "success", nw.description)
		ask(fd, CANCEL)
	}

	// Rate limiting (test mode: base 150 ms). The third failure in a row
	// earns 300 ms; an attempt inside that window is refused unchecked,
	// even with the right password; after it, the right password works.
	{
		for _ in 0 ..< 3 {
			login(fd, "limited", "wrong")
		}
		_, r := login(fd, "limited", "palm")
		check(
			"limit: the right password is refused while waiting",
			r.error_type == "auth_error" && strings.contains(r.description, "Too many"),
			r.description,
		)
		time.sleep(400 * time.Millisecond)
		_, ok := login(fd, "limited", "palm")
		check("limit: after the wait it works, and the count is cleared", ok.type == "success", ok.description)
		ask(fd, CANCEL)
		_, w := login(fd, "limited", "wrong")
		_, ok2 := login(fd, "limited", "palm")
		check("limit: one failure after a success costs only the base delay", w.error_type == "auth_error" && ok2.type == "success", ok2.description)
		ask(fd, CANCEL)
	}

	// Two greeters at once each get their own conversation.
	{
		fd2, ok := dial(sock)
		if ok {
			a1 := ask(fd, create("palm"))
			a2 := ask(fd2, create("root"))
			r2 := ask(fd2, respond("palm"))
			r1 := ask(fd, respond("palm"))
			check(
				"ipc: two connections, two conversations",
				a1.type == "auth_message" && a2.type == "auth_message" && r1.type == "success" && r2.type == "success",
			)
			linux.close(fd2)
		} else {
			check("ipc: second connection", false)
		}
	}

	// Garbage ends the connection with an error, and the daemon lives on.
	{
		r := ask(fd, `this is not json`)
		check("ipc: malformed JSON is an error", r.type == "error", r.description)
		after := answer(fd)
		check("ipc: ...and the connection is closed", after.type == "closed")
		linux.close(fd)

		fd3, ok := dial(sock)
		if ok {
			hdr := transmute([4]u8)u32(0x7fffffff)
			write_all(fd3, hdr[:])
			r3 := answer(fd3)
			check("ipc: an absurd frame length is refused", r3.type == "error", r3.description)
			linux.close(fd3)
		}
		fd4, ok4 := dial(sock)
		alive := false
		if ok4 {
			alive = ask(fd4, CANCEL).type == "success"
			linux.close(fd4)
		}
		check("ipc: the daemon is still serving afterwards", alive)
	}
}

// ---------------------------------------------------------------------------
// The session socket (session_ipc.odin)
// ---------------------------------------------------------------------------

@(private = "file")
start_test_daemon :: proc(dir, tag: string, extra: []string) -> (pid: linux.Pid, sock, ssock: string) {
	sock = fmt.tprintf("%s/%s.sock", dir, tag)
	ssock = fmt.tprintf("%s/%s.session.sock", dir, tag)
	list := make([dynamic]cstring, context.temp_allocator)
	for a in ([]string{
		"palm-login", "--test", "--sock", sock, "--session-sock", ssock,
		"--passwd", fmt.tprintf("%s/passwd", dir), "--shadow", fmt.tprintf("%s/shadow", dir),
		"--group", fmt.tprintf("%s/group", dir),
	}) {
		append(&list, strings.clone_to_cstring(a, context.temp_allocator))
	}
	for a in extra {
		append(&list, strings.clone_to_cstring(a, context.temp_allocator))
	}
	append(&list, nil)
	envp := []cstring{nil}
	logfd, _ := linux.open(
		strings.clone_to_cstring(fmt.tprintf("%s/%s.log", dir, tag), context.temp_allocator),
		{.WRONLY, .CREAT, .TRUNC},
		{.IRUSR, .IWUSR},
	)
	p, fe := linux.fork()
	if fe != .NONE {
		return -1, sock, ssock
	}
	if p == 0 {
		linux.dup2(logfd, 1)
		linux.dup2(logfd, 2)
		linux.execve("/proc/self/exe", raw_data(list[:]), raw_data(envp))
		linux.exit(127)
	}
	linux.close(logfd)
	for _ in 0 ..< 100 {
		if f, ok := dial(ssock); ok {
			linux.close(f)
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	return p, sock, ssock
}

@(private = "file")
stop_test_daemon :: proc(pid: linux.Pid) {
	if pid > 0 {
		linux.kill(pid, .SIGTERM)
		status: u32
		linux.wait4(pid, &status, {}, nil)
	}
}

@(private = "file")
unlock_req :: proc(pw: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"type":"unlock","password":`)
	json_quote(&sb, pw)
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

@(private = "file")
power_req :: proc(action: string, dry: bool, pw: Maybe(string) = nil) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, `{{"type":"power","action":"%s","dry_run":%v`, action, dry)
	if p, ok := pw.?; ok {
		strings.write_string(&sb, `,"password":`)
		json_quote(&sb, p)
	}
	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

// ask_once dials, asks one thing, hangs up.
@(private = "file")
ask_once :: proc(path, payload: string) -> Reply {
	fd, ok := dial(path)
	if !ok {
		return {type = "no-connect"}
	}
	defer linux.close(fd)
	return ask(fd, payload)
}

@(private = "file")
session_socket_tests :: proc() {
	dir := fmt.tprintf("/tmp/palm-login-session-selftest-%d", linux.getpid())
	os.make_directory(dir, os.perm(0o700))
	defer os.remove_all(dir)
	write :: proc(path, text: string) {
		_ = os.write_entire_file(path, transmute([]u8)text)
	}
	write(fmt.tprintf("%s/passwd", dir), FIXTURE_PASSWD)
	write(fmt.tprintf("%s/shadow", dir), FIXTURE_SHADOW)
	write(fmt.tprintf("%s/group", dir), FIXTURE_GROUP)
	vt := fmt.tprintf("%s/active", dir)
	write(vt, "tty1\n")
	utmp := fmt.tprintf("%s/utmp", dir)
	me := linux.getpid()
	uid := u32(linux.getuid())

	// The session as palm-login would have started it: this process is
	// its leader, and runs as its uid.
	pid, gsock, ssock := start_test_daemon(dir, "a", {
		"--session-user", "palm", "--session-uid", fmt.tprintf("%d", uid),
		"--session-leader", fmt.tprintf("%d", me), "--vt-active", vt, "--utmp", utmp,
	})
	defer stop_test_daemon(pid)
	{
		st: linux.Stat
		linux.stat(strings.clone_to_cstring(ssock, context.temp_allocator), &st)
		mode := transmute(u32)st.mode & 0o777
		check("session: the socket is 0600", mode == 0o600, fmt.tprintf("%o", mode))
	}

	t0 := time.tick_now()
	r := ask_once(ssock, unlock_req("wrong"))
	took := time.tick_since(t0)
	check("session: unlock with a wrong password is auth_error", r.type == "error" && r.error_type == "auth_error", r.description)
	check("session: ...answered late", took >= 140 * time.Millisecond, fmt.tprintf("%v", took))
	r = ask_once(ssock, unlock_req("palm"))
	check("session: unlock with the session user's password", r.type == "success", r.description)
	r = ask_once(ssock, unlock_req(""))
	check("session: an empty password does not unlock", r.error_type == "auth_error", r.description)

	r = ask_once(ssock, power_req("reboot", true))
	check("session: power dry run, alone on the machine: allowed", r.type == "success", r.description)
	r = ask_once(ssock, power_req("halt-and-catch-fire", true))
	check("session: an unknown power action is refused", r.type == "error", r.description)
	r = ask_once(ssock, create("palm"))
	check("session: greetd requests are refused on the session socket", r.type == "error" && strings.contains(r.description, "does not take"), r.description)
	r = ask_once(ssock, START)
	check("session: start_session is refused on the session socket", r.type == "error", r.description)
	r = ask_once(gsock, `{"type":"unlock","password":"palm"}`)
	check("session: unlock is not a greeter request", r.type == "error" && strings.contains(r.description, "unknown"), r.description)

	// Switched to another VT: not in front, so no power; unlock still works.
	write(vt, "tty2\n")
	r = ask_once(ssock, power_req("poweroff", true))
	check("session: power is refused while the session is not on screen", r.type == "error" && strings.contains(r.description, "on screen"), r.description)
	r = ask_once(ssock, unlock_req("palm"))
	check("session: ...unlock is not", r.type == "success", r.description)
	write(vt, "tty1\n")

	// Someone else logged in (root on the serial console, alive: our pid).
	auth.utmp_put(utmp, auth.make_utmp(auth.UT_USER_PROCESS, i32(me), "ttyS0", "S0", "root"))
	r = ask_once(ssock, power_req("poweroff", true))
	check(
		"session: others logged in: power asks for a password (palm is in wheel)",
		r.error_type == "auth_required" && strings.contains(r.description, "root on ttyS0"),
		r.description,
	)
	r = ask_once(ssock, power_req("poweroff", true, "nope"))
	check("session: ...a wrong one is refused", r.error_type == "auth_error", r.description)
	r = ask_once(ssock, power_req("poweroff", true, "palm"))
	check("session: ...the right one overrides", r.type == "success", r.description)
	auth.utmp_put(utmp, auth.make_utmp(auth.UT_DEAD_PROCESS, i32(me), "ttyS0", "S0", ""))
	r = ask_once(ssock, power_req("poweroff", true))
	check("session: once they have logged out, no password", r.type == "success", r.description)

	// The unlock rate limit (base 150 ms in test mode): after three
	// failures the right password is refused unchecked until the wait ends.
	{
		for _ in 0 ..< 3 {
			ask_once(ssock, unlock_req("wrong"))
		}
		r = ask_once(ssock, unlock_req("palm"))
		check("session: unlock is rate limited", r.error_type == "auth_error" && strings.contains(r.description, "Too many"), r.description)
		time.sleep(400 * time.Millisecond)
		r = ask_once(ssock, unlock_req("palm"))
		check("session: ...and works after the wait", r.type == "success", r.description)
	}

	// A process of the same user that is not part of the session: a
	// grandchild whose parent has exited, so it hangs under init (or a
	// subreaper), no longer below the session leader.
	{
		fds: [2]linux.Fd
		linux.pipe2(&fds, {.CLOEXEC})
		child, _ := linux.fork()
		if child == 0 {
			grand, _ := linux.fork()
			if grand != 0 {
				linux.exit(0)
			}
			for _ in 0 ..< 200 {
				if pp, ok := proc_ppid(i32(linux.getpid())); ok && pp != i32(child) && pp != 0 {
					break
				}
				time.sleep(5 * time.Millisecond)
			}
			rr := ask_once(ssock, unlock_req("palm"))
			msg := fmt.tprintf("%s|%s", rr.type, rr.description)
			linux.write(fds[1], transmute([]u8)msg)
			linux.exit(0)
		}
		linux.close(fds[1])
		status: u32
		linux.wait4(child, &status, {}, nil)
		buf: [256]u8
		pf := [1]linux.Poll_Fd{{fd = fds[0], events = {.IN}}}
		linux.poll(pf[:], 5000)
		n, _ := linux.read(fds[0], buf[:])
		linux.close(fds[0])
		got := string(buf[:max(n, 0)])
		check(
			"session: a process of the same user outside the session is refused",
			strings.has_prefix(got, "error|") && strings.contains(got, "process of the running session"),
			got,
		)
	}

	r = ask_once(ssock, power_req("reboot", false))
	check("session: power{reboot} from the session is accepted (test mode ends nothing)", r.type == "success", r.description)

	// Another user's session: our uid is not the one it was started as.
	{
		p2, _, s2 := start_test_daemon(dir, "b", {
			"--session-user", "palm", "--session-uid", fmt.tprintf("%d", uid + 1), "--session-leader", fmt.tprintf("%d", me),
		})
		r2 := ask_once(s2, unlock_req("palm"))
		check("session: another user is refused", r2.type == "error" && strings.contains(r2.description, "own user"), r2.description)
		r3 := ask_once(s2, power_req("poweroff", true))
		check("session: ...for power too", r3.type == "error" && strings.contains(r3.description, "own user"), r3.description)
		stop_test_daemon(p2)
	}
	// A session we are not part of (its leader is a kernel thread).
	{
		p3, _, s3 := start_test_daemon(dir, "c", {
			"--session-user", "palm", "--session-uid", fmt.tprintf("%d", uid), "--session-leader", "2",
		})
		r4 := ask_once(s3, power_req("poweroff", true))
		check("session: a process outside the session is refused", r4.type == "error" && strings.contains(r4.description, "process of the running session"), r4.description)
		stop_test_daemon(p3)
	}
	// No session at all (the greeter is up).
	{
		p4, _, s4 := start_test_daemon(dir, "d", {})
		r5 := ask_once(s4, unlock_req("palm"))
		check("session: with no session running, nothing is answered for", r5.type == "error" && strings.contains(r5.description, "no user session"), r5.description)
		stop_test_daemon(p4)
	}
}
