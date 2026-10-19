package passwd

// passwd — change a password.
//
//	passwd              change your own (asks for the current one first)
//	passwd USER         root: set USER's password, without the old one
//	passwd -l USER      root: lock the account (a '!' before the hash)
//	passwd -u USER      root: unlock it
//	passwd -e USER      root: expire the password, so it must be changed at
//	                    the next login (the greeter asks for a new one)
//	passwd -S [USER]    the status line: name, L/P/NP, last change, aging
//
// It is setuid root, because /etc/shadow is root's alone, and does in this
// order: the setuid prologue (auth/harden.odin); who is calling, from the
// real uid; for a user, the current password — once, rate limited and
// logged exactly like doas's, through the same /run/faillock count — and
// the `min` days of shadow aging; the new password twice, checked against
// the few rules of auth/quality.odin; then the real uid is made root too,
// so the caller can no longer signal the process, and /etc/shadow is
// rewritten atomically under both the lckpwdf and the busybox lock
// (auth/shadow_write.odin). The hash is SHA-512 crypt with a fresh salt,
// the same code palm-login checks it with.

import "core:fmt"
import "core:os"
import "core:sys/linux"
import "core:time"
import "../login/auth"

FAIL_DELAY :: 1500 * time.Millisecond

die :: proc(format: string, args: ..any) -> ! {
	fmt.eprint("passwd: ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

usage :: proc() -> ! {
	fmt.eprintln(
		"usage: passwd [USER]\n" +
		"       passwd -l|-u|-e USER     lock, unlock, expire (root)\n" +
		"       passwd -S [USER]         status",
	)
	os.exit(1)
}

Mode :: enum {
	Change,
	Lock,
	Unlock,
	Expire,
	Status,
}

main :: proc() {
	auth.setuid_prologue()

	mode := Mode.Change
	name := ""
	args := os.args[1:]
	for a in args {
		switch a {
		case "-l":
			mode = .Lock
		case "-u":
			mode = .Unlock
		case "-e":
			mode = .Expire
		case "-S":
			mode = .Status
		case "-h", "--help":
			usage()
		case:
			if len(a) > 0 && a[0] == '-' || name != "" {
				usage()
			}
			name = a
		}
	}

	ruid, euid, suid: linux.Uid
	linux.getresuid(&ruid, &euid, &suid)
	if euid != 0 {
		die("not installed setuid root")
	}
	uid := u32(ruid)
	auth.log_open("passwd")

	passwd_text, pok := auth.read_text(auth.PASSWD_PATH)
	if !pok {
		die("cannot read %s", auth.PASSWD_PATH)
	}
	me, mok := auth.parse_passwd_uid(passwd_text, uid)
	if !mok {
		die("who are you? (uid %d is not in %s)", uid, auth.PASSWD_PATH)
	}
	me = auth.clone_account(me)
	if name == "" {
		name = me.name
	}
	if !auth.valid_name(name) {
		die("%q is not a user name", auth.clean(name))
	}
	acct, found := auth.parse_passwd(passwd_text, name)
	if !found {
		die("unknown user %s", name)
	}
	acct = auth.clone_account(acct)
	if uid != 0 && acct.uid != uid {
		auth.logf(.Notice, "%s tried to change the password of %s", me.name, name)
		die("only root may change another user's password")
	}
	if uid != 0 && mode != .Change && mode != .Status {
		die("only root may lock, unlock or expire an account")
	}
	if acct.passwd != "x" {
		die("%s keeps its password in %s, not %s; not supported", name, auth.PASSWD_PATH, auth.SHADOW_PATH)
	}

	switch mode {
	case .Status:
		status(name)
	case .Lock:
		edit(name, proc(s: ^auth.Shadow, found: bool, _: rawptr) -> string {
			if !found {
				return "no shadow entry"
			}
			if len(s.hash) == 0 || s.hash[0] != '!' {
				s.hash = fmt.tprintf("!%s", s.hash)
			}
			return ""
		})
		auth.logf(.Notice, "%s locked %s", me.name, name)
		fmt.printfln("passwd: %s is locked", name)
	case .Unlock:
		edit(name, proc(s: ^auth.Shadow, found: bool, _: rawptr) -> string {
			if !found {
				return "no shadow entry"
			}
			if len(s.hash) > 0 && s.hash[0] == '!' {
				if len(s.hash) == 1 {
					return "unlocking would leave no password at all; set one with passwd USER"
				}
				s.hash = s.hash[1:]
			}
			return ""
		})
		auth.logf(.Notice, "%s unlocked %s", me.name, name)
		fmt.printfln("passwd: %s is unlocked", name)
	case .Expire:
		edit(name, proc(s: ^auth.Shadow, found: bool, _: rawptr) -> string {
			if !found {
				return "no shadow entry"
			}
			s.lastchg = 0
			return ""
		})
		auth.logf(.Notice, "%s expired the password of %s", me.name, name)
		fmt.printfln("passwd: %s must choose a new password at the next login", name)
	case .Change:
		change(me, acct, uid == 0)
	}
}

edit :: proc(name: string, f: auth.Shadow_Edit, data: rawptr = nil) {
	become_root()
	if e := auth.update_shadow(auth.SHADOW_PATH, name, f, data); e != "" {
		auth.logf(.Err, "could not update %s for %s: %s", auth.SHADOW_PATH, name, e)
		die("%s", e)
	}
}

// become_root makes the real and saved uid root as well, just before the
// write: from here on the caller cannot send this process any signal, so it
// cannot be stopped half way (the write also blocks every signal it can).
become_root :: proc() {
	if linux.setresuid(0, 0, 0) != .NONE || linux.setresgid(0, 0, 0) != .NONE {
		die("could not become root")
	}
}

status :: proc(name: string) {
	text, ok := auth.read_text(auth.SHADOW_PATH)
	if !ok {
		die("cannot read %s", auth.SHADOW_PATH)
	}
	s, found, _ := auth.parse_shadow_entry(text, name)
	if !found {
		die("%s has no shadow entry", name)
	}
	state := "P"
	if s.hash == "" {
		state = "NP"
	} else if s.hash[0] == '!' || s.hash[0] == '*' {
		state = "L"
	}
	day :: proc(n: i64) -> string {
		if n < 0 {
			return "-"
		}
		if n == 0 {
			return "must-change"
		}
		y, m, d := time.date(time.unix(n * 86400, 0))
		return fmt.tprintf("%04d-%02d-%02d", y, int(m), d)
	}
	num :: proc(n: i64) -> string {
		return n < 0 ? "-" : fmt.tprintf("%d", n)
	}
	// passwd -S's format from shadow-utils: name, state, last change, min,
	// max, warn, inactive.
	fmt.printfln("%s %s %s %s %s %s %s", name, state, day(s.lastchg), num(s.min), num(s.max), num(s.warn), num(s.inactive))
}

// change is the ordinary case.
change :: proc(me, acct: auth.Account, as_root: bool) {
	creds, _ := auth.load_credentials(auth.PASSWD_PATH, auth.SHADOW_PATH, acct.name)
	if !creds.has_shadow && !as_root {
		die("%s has no entry in %s; ask root", acct.name, auth.SHADOW_PATH)
	}
	if creds.has_shadow && !creds.shadow_valid {
		die("the %s line for %s is damaged; ask root", auth.SHADOW_PATH, acct.name)
	}

	old_buf: [auth.MAX_SECRET]u8
	defer auth.zero_bytes(old_buf[:])
	old := ""
	if !as_root {
		st, _ := auth.account_status(creds.shadow, auth.today())
		if st == .Account_Expired || st == .Inactive {
			auth.logf(.Notice, "refused %s: %v", acct.name, st)
			die("%s", auth.status_message(st))
		}
		if st != .Must_Change {
			if ok, wait := auth.may_change_yet(creds.shadow, auth.today()); !ok {
				die("the password was changed too recently; try again in %d day%s", wait, wait == 1 ? "" : "s")
			}
		}
		fmt.printfln("Changing the password of %s.", acct.name)
		old = check_current(acct, old_buf[:])
	} else {
		fmt.printfln("Setting the password of %s.", acct.name)
	}

	new_buf, again_buf: [auth.MAX_SECRET]u8
	defer auth.zero_bytes(new_buf[:])
	defer auth.zero_bytes(again_buf[:])
	pw: string
	for attempt := 0; ; attempt += 1 {
		if attempt == 3 {
			die("password unchanged")
		}
		p, ok := auth.read_secret("New password: ", new_buf[:])
		if !ok {
			die("password unchanged")
		}
		if problem := auth.password_problem(string(p), old, acct.name); problem != "" {
			if !as_root || len(p) == 0 {
				fmt.eprintln(problem)
				continue
			}
			// Root is told, and allowed.
			fmt.eprintfln("%s (accepted, because you are root)", problem)
		}
		a, aok := auth.read_secret("Retype new password: ", again_buf[:])
		if !aok {
			die("password unchanged")
		}
		if string(a) != string(p) {
			fmt.eprintln("The passwords did not match.")
			continue
		}
		pw = string(p)
		break
	}

	hash, hok := auth.make_hash(pw, allocator = context.temp_allocator)
	if !hok {
		die("could not hash the password")
	}
	Data :: struct {
		hash: string,
	}
	data := Data{hash}
	edit(acct.name, proc(s: ^auth.Shadow, found: bool, p: rawptr) -> string {
		if !found {
			// Only reachable as root: a fresh line, with aging off.
			s.max = 99999
			s.warn = 7
			s.min = 0
		}
		s.hash = (^Data)(p).hash
		s.lastchg = auth.today()
		return ""
	}, &data)
	auth.logf(.Notice, "password of %s changed by %s", acct.name, me.name)
	fmt.println("passwd: password updated")
}

// check_current asks for the current password, once, with the same rate
// limit and logging as doas.
check_current :: proc(acct: auth.Account, buf: []u8) -> string {
	{
		fl, err := auth.faillock_open(acct.uid)
		if err != "" {
			die("cannot check the failure count: %s", err)
		}
		w := auth.tally_remaining(fl.tally, auth.now_ms(), FAIL_DELAY)
		auth.faillock_close(&fl)
		if w > 0 {
			auth.logf(.Warning, "refused %s unchecked: too many failures, %s left", acct.name, auth.wait_words(w))
			die("too many failed attempts; try again in %s", auth.wait_words(w))
		}
	}
	pw, ok := auth.read_secret("Current password: ", buf)
	if !ok {
		die("a password is required, and none could be read from a terminal")
	}
	fl, err := auth.faillock_open(acct.uid)
	if err != "" {
		die("cannot check the failure count: %s", err)
	}
	now := auth.now_ms()
	if w := auth.tally_remaining(fl.tally, now, FAIL_DELAY); w > 0 {
		die("too many failed attempts; try again in %s", auth.wait_words(w))
	}
	auth.tally_fail(&fl.tally, now)
	auth.faillock_store(&fl)
	creds, found := auth.load_credentials(auth.PASSWD_PATH, auth.SHADOW_PATH, acct.name)
	if !auth.check_password(creds, found, string(pw)) {
		n := fl.tally.failures
		auth.faillock_close(&fl)
		auth.logf(
			.Notice,
			"authentication failure for %s (%d in a row; next attempt in %s)",
			acct.name,
			n,
			auth.wait_words(auth.tally_wait_for(n, FAIL_DELAY)),
		)
		time.sleep(FAIL_DELAY)
		die("Authentication failed; password unchanged")
	}
	fl.tally = {}
	auth.faillock_store(&fl)
	auth.faillock_close(&fl)
	return string(pw)
}
