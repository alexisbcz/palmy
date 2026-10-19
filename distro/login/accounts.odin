package login

// Accounts as palm-login sees them: where the files are, and the whole of
// "may this person log in?" — the rate limit, the password, then the aging
// fields. The parsers, the crypt and the shadow writer are in auth/, shared
// with doas and passwd.

import "auth"
import "core:fmt"
import "core:strings"
import "core:time"

Paths :: struct {
	passwd:      string,
	shadow:      string,
	group:       string,
	// The language and time zone every session inherits (locale.odin).
	locale_conf: string,
	timezone:    string,
	localtime:   string,
}

SYSTEM_PATHS :: Paths {
	passwd      = auth.PASSWD_PATH,
	shadow      = auth.SHADOW_PATH,
	group       = auth.GROUP_PATH,
	locale_conf = "/etc/locale.conf",
	timezone    = "/etc/timezone",
	localtime   = "/etc/localtime",
}

read_text :: auth.read_text

// lookup_account reads passwd from disk and finds `user`. The strings are
// cloned with `allocator` so the account outlives the temp allocator.
lookup_account :: proc(paths: Paths, user: string, allocator := context.allocator) -> (a: auth.Account, ok: bool) {
	text, rok := auth.read_text(paths.passwd)
	if !rok {
		return {}, false
	}
	found: bool
	a, found = auth.parse_passwd(text, user)
	if !found {
		return {}, false
	}
	return auth.clone_account(a, allocator), true
}

// ---------------------------------------------------------------------------
// Rate limiting (auth/ratelimit.odin has the policy)
// ---------------------------------------------------------------------------

// Two counts: one per account name, and one for the seat as a whole, so
// guessing across many names is slowed down too. The seat starts waiting
// only after SEAT_FREE failures in a row, so one person's typos never hold
// up another's login.
SEAT_FREE :: 8
MAX_TRACKED :: 512

Limits :: struct {
	users: map[string]auth.Tally,
	seat:  auth.Tally,
	base:  time.Duration,
}

// limits_wait is how long `user` must wait before an attempt is looked at.
limits_wait :: proc(l: ^Limits, user: string) -> time.Duration {
	now := auth.now_ms()
	auth.tally_refresh(&l.seat, now)
	seat := l.seat
	seat.failures = max(0, seat.failures - SEAT_FREE)
	w := auth.tally_remaining(seat, now, l.base)
	if t, ok := &l.users[user]; ok {
		auth.tally_refresh(t, now)
		w = max(w, auth.tally_remaining(t^, now, l.base))
	}
	return w
}

// limits_fail counts a failure and returns how many in a row `user` has.
limits_fail :: proc(l: ^Limits, user: string) -> int {
	now := auth.now_ms()
	auth.tally_fail(&l.seat, now)
	if !auth.valid_name(user) {
		return l.seat.failures
	}
	if len(l.users) >= MAX_TRACKED && user not_in l.users {
		// Only names that do not exist can fill it this far; forget them.
		for k in l.users {
			delete(k)
		}
		clear(&l.users)
	}
	if user not_in l.users {
		l.users[strings.clone(user)] = {}
	}
	t := &l.users[user]
	auth.tally_fail(t, now)
	return t.failures
}

limits_ok :: proc(l: ^Limits, user: string) {
	l.seat = {}
	if user in l.users {
		k, _ := delete_key(&l.users, user)
		delete(k)
	}
}

// ---------------------------------------------------------------------------
// The check
// ---------------------------------------------------------------------------

Auth_Result :: struct {
	ok:     bool, // the password was right
	wait:   time.Duration, // > 0: refused unchecked, try again after this
	status: auth.Status,
	days:   i64,
}

// check_login is the whole decision for the greeter's answer.
check_login :: proc(paths: Paths, limits: ^Limits, user, password: string) -> Auth_Result {
	if w := limits_wait(limits, user); w > 0 {
		auth.logf(.Warning, "refused %q unchecked: too many failures, %s left", auth.clean(user), auth.wait_words(w))
		return {wait = w}
	}
	c, found := auth.load_credentials(paths.passwd, paths.shadow, user)
	if !auth.check_password(c, found, password) {
		n := limits_fail(limits, user)
		wait := auth.tally_wait_for(n, limits.base)
		auth.logf(
			.Notice,
			"authentication failure for %q (%d in a row; next attempt in %s)",
			auth.clean(user),
			n,
			auth.wait_words(wait),
		)
		return {}
	}
	limits_ok(limits, user)
	r := Auth_Result{ok = true}
	if c.has_shadow {
		r.status, r.days = auth.account_status(c.shadow, auth.today())
	}
	return r
}

// set_password writes a new hash for `user` (an expired password changed at
// the greeter).
set_password :: proc(paths: Paths, user, password: string) -> string {
	h, ok := auth.make_hash(password, allocator = context.temp_allocator)
	if !ok {
		return "could not hash the password"
	}
	Data :: struct {
		hash: string,
	}
	data := Data{h}
	edit :: proc(s: ^auth.Shadow, found: bool, p: rawptr) -> string {
		if !found {
			return "the account has no shadow entry"
		}
		s.hash = (^Data)(p).hash
		s.lastchg = auth.today()
		return ""
	}
	if e := auth.update_shadow(paths.shadow, user, edit, &data); e != "" {
		return e
	}
	return ""
}

describe_wait :: proc(w: time.Duration) -> string {
	return fmt.tprintf("Too many failed attempts. Try again in %s.", auth.wait_words(w))
}
