package doas

// doas — run a command as another user, usually root.
//
// OpenBSD's doas, rewritten small for Palmframe: a setuid-root program that
// reads one policy file (/etc/doas.conf, conf.odin), asks the caller for
// their own password, and runs the command as the target user with a clean
// environment (policy.odin). The password check, the rate limit and the
// logging are palm-login's (distro/login/auth), so there is one SHA-512
// crypt in the system and one notion of "too many failures".
//
//	doas [-nsL] [-u user] [--] command [args ...]
//	doas -C config [command [args ...]]
//
//	-u user    run as user instead of root
//	-s         run the target's shell (the caller's $SHELL if absolute, else
//	           the caller's login shell, as OpenBSD does)
//	-n         never ask: fail if a password would be needed
//	-L         forget this terminal's `persist` authentication, and exit
//	-C config  check a configuration file, as the caller, without privileges;
//	           with a command, print what the rules decide for it
//
// What it will not do, in order of the checks:
//
//	run unless it is setuid root, and its own descriptors 0-2, limits and
//	    umask are sane (auth/harden.odin)
//	trust $USER: the caller is the real uid, looked up in /etc/passwd
//	read a policy that is not root's, or that anyone else may write; or use
//	    a policy with any error in it
//	run a command no rule permits (the last matching rule wins)
//	ask for a password more than once per run, or at all while the caller
//	    is waiting out earlier failures (the wait doubles from the third
//	    failure on, up to a minute; auth/ratelimit.odin)
//	accept an expired account or password
//	look a command up in anything but /usr/local/bin:/usr/bin:/bin
//	pass on LD_*, and anything outside a short list, of the caller's
//	    environment
//	run the command unless setgroups, setgid and setuid all took
//
// Every grant and every refusal is logged to syslog (authpriv), which the
// `syslog` service writes to /var/log/messages.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "../login/auth"

FAIL_DELAY :: 1500 * time.Millisecond

die :: proc(format: string, args: ..any) -> ! {
	fmt.eprint("doas: ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

usage :: proc() -> ! {
	fmt.eprintln("usage: doas [-nsL] [-u user] [--] command [args ...]\n       doas -C config [command [args ...]]")
	os.exit(1)
}

main :: proc() {
	auth.setuid_prologue()

	// Options, getopt-style, stopping at the first word that is not one.
	args := os.args[1:]
	target_name := "root"
	nonint, shell, clear_persist := false, false, false
	check_conf := ""
	i := 0
	opts: for i < len(args) {
		a := args[i]
		if a == "--" {
			i += 1
			break
		}
		if len(a) < 2 || a[0] != '-' {
			break
		}
		for j := 1; j < len(a); j += 1 {
			switch a[j] {
			case 'n':
				nonint = true
			case 's':
				shell = true
			case 'L':
				clear_persist = true
			case 'u', 'C':
				val := a[j + 1:]
				if val == "" {
					i += 1
					if i >= len(args) {
						usage()
					}
					val = args[i]
				}
				if a[j] == 'u' {
					target_name = val
				} else {
					check_conf = val
				}
				i += 1
				continue opts
			case:
				usage()
			}
		}
		i += 1
	}
	argv := args[i:]

	ruid, euid, suid: linux.Uid
	linux.getresuid(&ruid, &euid, &suid)
	uid := u32(ruid)

	if check_conf != "" {
		check_mode(check_conf, argv, uid)
	}
	if euid != 0 {
		die("not installed setuid root")
	}

	auth.log_open("doas")

	passwd_text, pok := auth.read_text(auth.PASSWD_PATH)
	group_text, _ := auth.read_text(auth.GROUP_PATH)
	if !pok {
		die("cannot read %s", auth.PASSWD_PATH)
	}
	me_acct, mok := auth.parse_passwd_uid(passwd_text, uid)
	if !mok {
		die("who are you? (uid %d is not in %s)", uid, auth.PASSWD_PATH)
	}
	me := auth.clone_account(me_acct, context.allocator)

	if clear_persist {
		persist_clear(persist_key(uid))
		os.exit(0)
	}
	if shell == (len(argv) > 0) {
		usage()
	}

	target_acct, tok := auth.parse_passwd(passwd_text, target_name)
	if !tok {
		die("unknown user %s", auth.clean(target_name))
	}
	target := auth.clone_account(target_acct, context.allocator)

	if shell {
		sh := os.get_env("SHELL", context.temp_allocator)
		if !strings.has_prefix(sh, "/") {
			sh = me.shell != "" ? me.shell : "/bin/sh"
		}
		argv = []string{sh}
	}

	cmd_path, found := resolve(argv[0])
	if !found {
		die("%s: command not found", auth.clean(argv[0]))
	}

	conf_text, cerr := read_conf(CONF_PATH)
	if cerr != "" {
		auth.logf(.Err, "%s", cerr)
		die("%s", cerr)
	}
	rules, perr := parse_conf(conf_text)
	if perr != "" {
		auth.logf(.Err, "%s: %s", CONF_PATH, perr)
		die("%s: syntax error at %s", CONF_PATH, perr)
	}

	who := Who{name = me.name, uid = uid, groups = caller_groups()}
	req := Request{who = who, target = target, cmd = argv[0], cmd_path = cmd_path, args = argv[1:]}
	rule, matched := match_rules(rules[:], req, passwd_text, group_text)
	cmdline := auth.clean_argv(argv)
	if !matched || rule.action != .Permit {
		auth.logf(.Notice, "command not permitted for %s as %s: %s", me.name, target.name, cmdline)
		die("Operation not permitted")
	}

	if !rule.nopass {
		key := rule.persist ? persist_key(uid) : ""
		if !(rule.persist && persist_valid(key)) {
			if nonint {
				die("Authentication required")
			}
			authenticate(me)
			if rule.persist {
				persist_set(key)
			}
		}
	}

	if !rule.nolog {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		auth.logf(.Info, "%s ran command as %s from %s: %s", me.name, target.name, auth.clean(cwd), cmdline)
	}

	caller_env, _ := os.environ(context.temp_allocator)
	env := build_env(caller_env, rule, me.name, target)
	groups := auth.parse_groups(group_text, target.name, target.gid, context.temp_allocator)
	run(cmd_path, argv, env, target, groups)
}

// caller_groups is the kernel's view of the caller: the real gid and the
// supplementary groups, not what /etc/group says today.
caller_groups :: proc() -> []u32 {
	buf: [256]linux.Gid
	n, e := linux.getgroups(buf[:])
	out := make([dynamic]u32, context.temp_allocator)
	append(&out, u32(linux.getgid()))
	if e == .NONE {
		for g in buf[:n] {
			append(&out, u32(g))
		}
	}
	return out[:]
}

// authenticate asks the caller for their own password, once. A failure is
// counted, logged, answered late, and fatal.
authenticate :: proc(me: auth.Account) {
	// Waiting out earlier failures? Then do not even ask.
	{
		fl, err := auth.faillock_open(me.uid)
		if err != "" {
			auth.logf(.Err, "faillock: %s", err)
			die("cannot check the failure count: %s", err)
		}
		w := auth.tally_remaining(fl.tally, auth.now_ms(), FAIL_DELAY)
		auth.faillock_close(&fl)
		if w > 0 {
			auth.logf(.Warning, "refused %s unchecked: too many failures, %s left", me.name, auth.wait_words(w))
			die("too many failed attempts; try again in %s", auth.wait_words(w))
		}
	}

	host := hostname()
	buf: [auth.MAX_SECRET]u8
	defer auth.zero_bytes(buf[:])
	pw, ok := auth.read_secret(fmt.tprintf("doas (%s@%s) password: ", me.name, host), buf[:])
	if !ok {
		die("a password is required, and none could be read from a terminal")
	}

	fl, err := auth.faillock_open(me.uid)
	if err != "" {
		die("cannot check the failure count: %s", err)
	}
	now := auth.now_ms()
	if w := auth.tally_remaining(fl.tally, now, FAIL_DELAY); w > 0 {
		auth.faillock_close(&fl)
		die("too many failed attempts; try again in %s", auth.wait_words(w))
	}
	// Written down before the check: copies of doas started side by side
	// each count, rather than all reading "no failures" and guessing at once.
	auth.tally_fail(&fl.tally, now)
	auth.faillock_store(&fl)

	creds, found := auth.load_credentials(auth.PASSWD_PATH, auth.SHADOW_PATH, me.name)
	good := auth.check_password(creds, found, string(pw))
	auth.zero_bytes(buf[:])
	if !good {
		n := fl.tally.failures
		auth.faillock_close(&fl)
		auth.logf(
			.Notice,
			"authentication failure for %s (%d in a row; next attempt in %s)",
			me.name,
			n,
			auth.wait_words(auth.tally_wait_for(n, FAIL_DELAY)),
		)
		time.sleep(FAIL_DELAY)
		die("Authentication failed")
	}
	fl.tally = {}
	auth.faillock_store(&fl)
	auth.faillock_close(&fl)

	if creds.has_shadow {
		st, _ := auth.account_status(creds.shadow, auth.today())
		switch st {
		case .Account_Expired, .Inactive:
			auth.logf(.Notice, "refused %s: %v", me.name, st)
			die("%s", auth.status_message(st))
		case .Must_Change:
			auth.logf(.Notice, "refused %s: the password has expired", me.name)
			die("your password has expired; change it with passwd first")
		case .Ok, .Warn:
		}
	}
}

hostname :: proc() -> string {
	u: linux.UTS_Name
	if linux.uname(&u) == .NONE {
		return strings.clone_from_cstring(cstring(raw_data(u.nodename[:])), context.temp_allocator)
	}
	return "localhost"
}

// run becomes the target and executes the command. It never returns.
run :: proc(path: string, argv: []string, env: []string, target: auth.Account, groups: []u32) -> ! {
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv {
		cargv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	}
	cenv := make([]cstring, len(env) + 1, context.temp_allocator)
	for e, i in env {
		cenv[i] = strings.clone_to_cstring(e, context.temp_allocator)
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	gids := make([]linux.Gid, len(groups), context.temp_allocator)
	for g, i in groups {
		gids[i] = linux.Gid(g)
	}
	uid := linux.Uid(target.uid)
	gid := linux.Gid(target.gid)

	if e := linux.setgroups(gids); e != .NONE {
		die("setgroups: %v", e)
	}
	if e := linux.setresgid(gid, gid, linux.Uid(gid)); e != .NONE {
		die("setresgid: %v", e)
	}
	if e := linux.setresuid(uid, uid, uid); e != .NONE {
		die("setresuid: %v", e)
	}
	r, ef, s: linux.Uid
	linux.getresuid(&r, &ef, &s)
	if r != uid || ef != uid || s != uid || (uid != 0 && linux.setuid(0) == .NONE) {
		die("dropping to %s did not stick", target.name)
	}
	linux.umask({.IWGRP, .IWOTH})
	e := linux.execve(cpath, raw_data(cargv), raw_data(cenv))
	die("%s: %v", auth.clean(path), e)
}

// check_mode is -C: no privileges at all from the first line, so the file
// read is one the caller could read anyway.
check_mode :: proc(path: string, argv: []string, uid: u32) -> ! {
	gid := linux.getgid()
	if linux.setresgid(gid, gid, linux.Uid(gid)) != .NONE {
		die("could not drop privileges")
	}
	if linux.setresuid(linux.Uid(uid), linux.Uid(uid), linux.Uid(uid)) != .NONE {
		die("could not drop privileges")
	}
	if linux.geteuid() != linux.Uid(uid) {
		die("could not drop privileges")
	}
	text, err := read_conf(path, need_root_owned = false)
	if err != "" {
		die("%s", err)
	}
	rules, perr := parse_conf(text)
	if perr != "" {
		die("%s: syntax error at %s", path, perr)
	}
	if len(argv) == 0 {
		os.exit(0)
	}
	passwd_text, _ := auth.read_text(auth.PASSWD_PATH)
	group_text, _ := auth.read_text(auth.GROUP_PATH)
	me, mok := auth.parse_passwd_uid(passwd_text, uid)
	root, rok := auth.parse_passwd(passwd_text, "root")
	if !mok || !rok {
		die("cannot read the accounts")
	}
	cmd_path, _ := resolve(argv[0])
	req := Request {
		who      = Who{name = me.name, uid = uid, groups = caller_groups()},
		target   = root,
		cmd      = argv[0],
		cmd_path = cmd_path,
		args     = argv[1:],
	}
	rule, matched := match_rules(rules[:], req, passwd_text, group_text)
	if !matched || rule.action != .Permit {
		fmt.println("deny")
		os.exit(1)
	}
	fmt.println(rule.nopass ? "permit nopass" : "permit")
	os.exit(0)
}
