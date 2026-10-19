package auth

// `odin test distro/login/auth`: the shared pieces on their own. Built only
// by `odin test`, never into palm-login, doas or passwd.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"

@(test)
test_aging :: proc(t: ^testing.T) {
	day: i64 = 20000
	s := Shadow{lastchg = 19000, min = NONE, max = 99999, warn = 7, inactive = NONE, expire = NONE}
	st, _ := account_status(s, day)
	testing.expect_value(t, st, Status.Ok)

	s.lastchg = 0
	st, _ = account_status(s, day)
	testing.expect_value(t, st, Status.Must_Change)

	s = Shadow{lastchg = day - 95, max = 100, warn = 7, inactive = NONE, expire = NONE, min = NONE}
	n: i64
	st, n = account_status(s, day)
	testing.expect_value(t, st, Status.Warn)
	testing.expect_value(t, n, 5)

	s.lastchg = day - 100
	st, _ = account_status(s, day)
	testing.expect_value(t, st, Status.Must_Change)

	s.inactive = 3
	s.lastchg = day - 103
	st, _ = account_status(s, day)
	testing.expect_value(t, st, Status.Inactive)

	s.expire = day
	st, _ = account_status(s, day)
	testing.expect_value(t, st, Status.Account_Expired)

	// Empty max, empty lastchg: aging off.
	st, _ = account_status(Shadow{lastchg = NONE, max = 10, min = NONE, warn = NONE, inactive = NONE, expire = NONE}, day)
	testing.expect_value(t, st, Status.Ok)

	ok, wait := may_change_yet(Shadow{lastchg = day - 1, min = 3}, day)
	testing.expect(t, !ok && wait == 2)
	ok, _ = may_change_yet(Shadow{lastchg = day - 3, min = 3}, day)
	testing.expect(t, ok)
}

@(test)
test_shadow_lines :: proc(t: ^testing.T) {
	line := "palm:$6$x$y:19000:0:99999:7:::"
	s, found, valid := parse_shadow_entry(line, "palm")
	testing.expect(t, found && valid)
	testing.expect_value(t, s.lastchg, 19000)
	testing.expect_value(t, s.inactive, NONE)
	testing.expect_value(t, format_shadow(s), line)

	_, f2, v2 := parse_shadow_entry("palm:h:abc:::::::", "palm")
	testing.expect(t, f2 && !v2) // damaged day field: found, not valid

	_, f3, v3 := parse_shadow_entry("palm:h:1:2:3:4:5:6:7:8", "palm")
	testing.expect(t, f3 && !v3) // ten fields

	c := Credentials{acct = {passwd = "x"}, shadow = {hash = "$6$a$b"}, has_shadow = true, shadow_valid = false}
	testing.expect_value(t, stored_hash(c), "")
}

@(test)
test_names :: proc(t: ^testing.T) {
	testing.expect(t, valid_name("palm") && valid_name("a.b-c_d"))
	testing.expect(t, !valid_name("") && !valid_name("-x") && !valid_name("a/b") && !valid_name("..") && !valid_name("a\nb"))
	testing.expect(t, !valid_name(strings.repeat("a", 33, context.temp_allocator)))
}

@(test)
test_quality :: proc(t: ^testing.T) {
	testing.expect(t, password_problem("abc", "", "palm") != "")
	testing.expect(t, password_problem("palmpalm", "palmpalm", "palm") != "")
	testing.expect(t, password_problem("Palmer", "", "palmer") != "")
	testing.expect(t, password_problem("ünïcödé", "", "palm") == "") // 7 characters, more bytes
	testing.expect(t, password_problem("tab\there", "", "palm") != "")
	testing.expect(t, password_problem("correct horse", "palm", "palm") == "")
}

@(test)
test_ratelimit :: proc(t: ^testing.T) {
	base := 1500 * time.Millisecond
	testing.expect_value(t, tally_wait_for(1, base), base)
	testing.expect_value(t, tally_wait_for(2, base), base)
	testing.expect_value(t, tally_wait_for(3, base), 3 * time.Second)
	testing.expect_value(t, tally_wait_for(7, base), 48 * time.Second)
	testing.expect_value(t, tally_wait_for(8, base), MAX_WAIT)
	testing.expect_value(t, tally_wait_for(1000, base), MAX_WAIT)

	tl: Tally
	tally_fail(&tl, 1000)
	tally_fail(&tl, 1000)
	tally_fail(&tl, 1000)
	testing.expect_value(t, tally_remaining(tl, 1000, base), 3 * time.Second)
	testing.expect_value(t, tally_remaining(tl, 3999, base), time.Millisecond)
	testing.expect_value(t, tally_remaining(tl, 4000, base), 0)
	tally_refresh(&tl, 1000 + 16 * 60 * 1000)
	testing.expect_value(t, tl.failures, 0)
	// A clock that went backwards (it cannot, but a damaged file could
	// claim it): forget rather than wait forever.
	tally_fail(&tl, 5000)
	tally_refresh(&tl, 10)
	testing.expect_value(t, tl.failures, 0)
}

@(private = "file")
tmpdir :: proc(name: string) -> string {
	dir := fmt.tprintf("/tmp/palm-auth-test-%s-%d", name, linux.getpid())
	os.remove_all(dir)
	os.make_directory(dir, os.perm(0o700))
	return dir
}

@(test)
test_update_shadow :: proc(t: ^testing.T) {
	dir := tmpdir("shadow")
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/shadow", dir)
	before := "root:$6$r$r:19000:0:99999:7:::\n# a comment stays\npalm:$6$p$p:19000:0:99999:7:::\n\nguest:!:19000::::::\n"
	_ = os.write_entire_file(path, transmute([]u8)before)
	linux.chmod(strings.clone_to_cstring(path, context.temp_allocator), {.IRUSR, .IWUSR})

	set_hash :: proc(s: ^Shadow, found: bool, p: rawptr) -> string {
		s.hash = (^string)(p)^
		s.lastchg = 20000
		return ""
	}
	h := "$6$new$hash"
	testing.expect_value(t, update_shadow(path, "palm", set_hash, &h), "")
	after, _ := read_text(path)
	testing.expect_value(
		t,
		after,
		"root:$6$r$r:19000:0:99999:7:::\n# a comment stays\npalm:$6$new$hash:20000:0:99999:7:::\n\nguest:!:19000::::::\n",
	)
	bak, _ := read_text(fmt.tprintf("%s/shadow-", dir))
	testing.expect_value(t, bak, before)
	testing.expect(t, !os.exists(fmt.tprintf("%s/shadow+", dir)))
	st: linux.Stat
	linux.stat(strings.clone_to_cstring(path, context.temp_allocator), &st)
	testing.expect_value(t, transmute(u32)st.mode & 0o777, 0o600)

	// A user with no line gets one appended.
	testing.expect_value(t, update_shadow(path, "newbie", set_hash, &h), "")
	after, _ = read_text(path)
	testing.expect(t, strings.has_suffix(after, "newbie:$6$new$hash:20000::::::\n"), after)

	// An edit that refuses changes nothing.
	refuse :: proc(s: ^Shadow, found: bool, p: rawptr) -> string {return "no"}
	testing.expect_value(t, update_shadow(path, "palm", refuse, nil), "no")
	again, _ := read_text(path)
	testing.expect_value(t, again, after)

	// A hash with a colon or newline would corrupt the file.
	bad := "x:y"
	testing.expect(t, update_shadow(path, "palm", set_hash, &bad) != "")
	bad2 := "x\nroot::0:::::::"
	testing.expect(t, update_shadow(path, "palm", set_hash, &bad2) != "")
	again, _ = read_text(path)
	testing.expect_value(t, again, after)

	// A stale shadow+ (busybox's lock) is cleared once it is old; a damaged
	// line is refused, not rewritten.
	plus := fmt.tprintf("%s/shadow+", dir)
	_ = os.write_entire_file(plus, transmute([]u8)string("half"))
	old := linux.Time_Spec{time_sec = uint(time.time_to_unix(time.now()) - 600)}
	times := [2]linux.Time_Spec{old, old}
	linux.utimensat(linux.AT_FDCWD, strings.clone_to_cstring(plus, context.temp_allocator), &times[0], {})
	testing.expect_value(t, update_shadow(path, "palm", set_hash, &h), "")
	testing.expect(t, !os.exists(plus))

	_ = os.write_entire_file(path, transmute([]u8)string("palm:$6$p$p:notaday::::::\n"))
	testing.expect(t, update_shadow(path, "palm", set_hash, &h) != "")
	testing.expect(t, update_shadow(path, "../etc", set_hash, &h) != "")
}

@(test)
test_utmp :: proc(t: ^testing.T) {
	dir := tmpdir("utmp")
	defer os.remove_all(dir)
	p := Utmp_Paths{fmt.tprintf("%s/utmp", dir), fmt.tprintf("%s/wtmp", dir), fmt.tprintf("%s/lastlog", dir)}
	record_boot(p, 30)
	record_login(p, 4242, "seat0", "s0", "palm", 1000)
	record_logout(p, 4242, "seat0", "s0")
	record_login(p, 4343, "seat0", "s0", "palm", 1000)

	u, _ := read_text(p.utmp)
	w, _ := read_text(p.wtmp)
	// utmp: the boot record and one slot for seat0, reused.
	testing.expect_value(t, len(u), 2 * size_of(Utmp))
	// wtmp: boot, login, logout, login.
	testing.expect_value(t, len(w), 4 * size_of(Utmp))
	recs := ([^]Utmp)(raw_data(w))[:4]
	testing.expect_value(t, recs[0].type, UT_BOOT_TIME)
	testing.expect_value(t, recs[1].type, UT_USER_PROCESS)
	testing.expect_value(t, string(cstring(raw_data(recs[1].user[:]))), "palm")
	testing.expect_value(t, string(cstring(raw_data(recs[1].line[:]))), "seat0")
	testing.expect_value(t, recs[2].type, UT_DEAD_PROCESS)
	testing.expect_value(t, recs[3].pid, 4343)
	slot := ([^]Utmp)(raw_data(u))[1]
	testing.expect_value(t, slot.type, UT_USER_PROCESS)
	testing.expect_value(t, slot.pid, 4343)

	ll, ok := lastlog_get(p.lastlog, 1000)
	testing.expect(t, ok && ll.time > 0)
	_, none := lastlog_get(p.lastlog, 1001)
	testing.expect(t, !none)

	// A torn record at the end of wtmp is overwritten, not appended after.
	f, _ := os.open(p.wtmp, {.Write, .Append})
	os.write(f, []u8{1, 2, 3})
	os.close(f)
	record_logout(p, 4343, "seat0", "s0")
	w, _ = read_text(p.wtmp)
	testing.expect_value(t, len(w), 5 * size_of(Utmp))
}

@(test)
test_utmp_logins :: proc(t: ^testing.T) {
	dir := tmpdir("utmp-logins")
	defer os.remove_all(dir)
	p := Utmp_Paths{fmt.tprintf("%s/utmp", dir), fmt.tprintf("%s/wtmp", dir), fmt.tprintf("%s/lastlog", dir)}
	me := i32(linux.getpid())
	record_boot(p, 30)
	// The graphical seat (skipped), root on the serial console (alive: our
	// own pid), a login whose process is gone (no such pid), and a line
	// that logged out.
	record_login(p, me, "seat0", "s0", "palm", 1000)
	record_login(p, me, "ttyS0", "S0", "root", 0)
	record_login(p, 0x3ffffff0, "tty2", "2", "palm", 1000)
	record_login(p, me, "tty3", "3", "palm", 1000)
	record_logout(p, me, "tty3", "3")

	got := utmp_logins(p.utmp, "seat0", context.temp_allocator)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].user, "root")
		testing.expect_value(t, got[0].line, "ttyS0")
	}
	testing.expect_value(t, len(utmp_logins(fmt.tprintf("%s/none", dir), "seat0", context.temp_allocator)), 0)
}
