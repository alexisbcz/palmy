package auth

// Password aging and account expiry: the day fields of /etc/shadow.
//
//	name:hash:lastchg:min:max:warn:inactive:expire:
//
// The rules are shadow-utils' (lib/isexpired.c), which is what every other
// Linux login program follows, so an account set up with `chage` elsewhere
// behaves the same here:
//
//	expire set and today >= expire              the account has expired: no login
//	lastchg == 0                                the password must be changed now
//	lastchg+max+inactive <= today               expired for longer than the grace
//	                                            period: no login, an administrator
//	                                            must reset it
//	lastchg+max <= today                        expired: change it to log in
//	lastchg+max-warn <= today                   still fine, but say how long is left
//
// An empty lastchg or max, or a max of 10000 days or more (Palmframe's own
// accounts use the customary 99999), switches aging off.

import "core:time"

Status :: enum u8 {
	Ok,
	// The password works, and expires in `days` days: say so.
	Warn,
	// The password is right but must be changed before anything else.
	Must_Change,
	// Expired for longer than `inactive` days: no login at all.
	Inactive,
	// The account itself expired (the eighth field).
	Account_Expired,
}

// today is the day number shadow counts in.
today :: proc() -> i64 {
	return time.time_to_unix(time.now()) / 86400
}

// account_status applies the rules above. `days` is how many days are left
// for Warn.
account_status :: proc(s: Shadow, day: i64) -> (st: Status, days: i64) {
	if s.expire > 0 && day >= s.expire {
		return .Account_Expired, 0
	}
	if s.lastchg == 0 {
		return .Must_Change, 0
	}
	if s.lastchg < 0 || s.max < 0 || s.max >= 10000 {
		return .Ok, 0
	}
	ends := s.lastchg + s.max
	if s.inactive >= 0 && day >= ends + s.inactive {
		return .Inactive, 0
	}
	if day >= ends {
		return .Must_Change, 0
	}
	if s.warn > 0 && day >= ends - s.warn {
		return .Warn, ends - day
	}
	return .Ok, 0
}

// status_message is the sentence a person reads for a status that stops a
// login.
status_message :: proc(st: Status) -> string {
	switch st {
	case .Account_Expired:
		return "This account has expired. Ask an administrator."
	case .Inactive:
		return "This password expired too long ago. Ask an administrator to reset it."
	case .Must_Change:
		return "The password has expired and must be changed."
	case .Ok, .Warn:
	}
	return ""
}

// may_change_yet: the `min` field, the fewest days between two changes a
// user may make of their own password (root is not bound by it, and neither
// is a password that has already expired).
may_change_yet :: proc(s: Shadow, day: i64) -> (ok: bool, wait_days: i64) {
	if s.min <= 0 || s.lastchg <= 0 {
		return true, 0
	}
	if day < s.lastchg + s.min {
		return false, s.lastchg + s.min - day
	}
	return true, 0
}
