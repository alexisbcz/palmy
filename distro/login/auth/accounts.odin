package auth

// The three account databases: /etc/passwd, /etc/shadow, /etc/group.
//
// There is no NSS here and no PAM. Palmy's accounts are flat files and
// palm-login, doas and passwd read them directly, the same way busybox's
// login does. The parsers take the text rather than a path so the selftests
// can feed them fixtures, and so --test modes can point at files the
// invoking user owns.
//
// Every file is re-read on every attempt. They are small, and reading them
// fresh means a `passwd` takes effect at the next attempt without restarting
// anything.

import "core:os"
import "core:strconv"
import "core:strings"

PASSWD_PATH :: "/etc/passwd"
SHADOW_PATH :: "/etc/shadow"
GROUP_PATH :: "/etc/group"

Account :: struct {
	name:   string,
	uid:    u32,
	gid:    u32,
	gecos:  string,
	home:   string,
	shell:  string,
	// The password field of /etc/passwd. Almost always "x", meaning "look in
	// /etc/shadow"; anything else is a hash kept in passwd itself, which old
	// systems did and which is honoured for completeness.
	passwd: string,
}

// Shadow is one line of /etc/shadow (shadow(5)). The day counts are days
// since 1970-01-01; NONE stands for an empty field, which means "no such
// rule" — not zero, which for `lastchg` means "must change at next login".
Shadow :: struct {
	name:     string,
	hash:     string,
	lastchg:  i64,
	min:      i64,
	max:      i64,
	warn:     i64,
	inactive: i64,
	expire:   i64,
	// The ninth field, reserved; kept so rewriting a line does not lose it.
	flag:     string,
}

NONE :: i64(-1)

// colon_fields splits one line of a colon-separated database. Comments and
// blank lines yield nothing.
@(private = "file")
colon_fields :: proc(line: string, allocator := context.temp_allocator) -> []string {
	l := strings.trim_right(line, "\r")
	if l == "" || strings.has_prefix(l, "#") {
		return nil
	}
	f, _ := strings.split(l, ":", allocator)
	return f
}

@(private = "file")
parse_id :: proc(s: string) -> (u32, bool) {
	n, ok := strconv.parse_u64_of_base(s, 10)
	if !ok || n > u64(max(u32)) {
		return 0, false
	}
	return u32(n), true
}

// parse_days reads one of shadow's day fields. Empty is NONE; anything that
// is not a plain non-negative number is an error, so a damaged line is
// noticed rather than read as "no expiry".
parse_days :: proc(s: string) -> (i64, bool) {
	if s == "" {
		return NONE, true
	}
	n, ok := strconv.parse_u64_of_base(s, 10)
	if !ok || n > 1 << 40 {
		return 0, false
	}
	return i64(n), true
}

// parse_passwd finds `user` in the text of an /etc/passwd. Strings in the
// result are slices of `text`.
parse_passwd :: proc(text: string, user: string) -> (a: Account, found: bool) {
	return find_passwd(text, user, 0, false)
}

// parse_passwd_uid finds the first account with `uid`: who the caller of a
// setuid program is, from the kernel's real uid rather than from $USER.
parse_passwd_uid :: proc(text: string, uid: u32) -> (a: Account, found: bool) {
	return find_passwd(text, "", uid, true)
}

@(private = "file")
find_passwd :: proc(text: string, user: string, uid: u32, by_uid: bool) -> (a: Account, found: bool) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		f := colon_fields(line)
		if len(f) < 7 {
			continue
		}
		if !by_uid && f[0] != user {
			continue
		}
		u, uok := parse_id(f[2])
		g, gok := parse_id(f[3])
		if by_uid {
			if !uok || !gok || u != uid || f[0] == "" {
				continue
			}
		} else if !uok || !gok {
			// A malformed line for the very user asked about: refuse, rather
			// than fall through to a later duplicate.
			return {}, false
		}
		return Account{name = f[0], passwd = f[1], uid = u, gid = g, gecos = f[4], home = f[5], shell = f[6]}, true
	}
	return {}, false
}

// parse_shadow returns the hash field for `user` in the text of an
// /etc/shadow.
parse_shadow :: proc(text: string, user: string) -> (hash: string, found: bool) {
	s, ok, _ := parse_shadow_entry(text, user)
	return s.hash, ok
}

// parse_shadow_entry returns the whole line for `user`. A line whose day
// fields do not parse is reported as found but with `valid` false: callers
// treat that as a locked account, never as one without rules.
parse_shadow_entry :: proc(text: string, user: string) -> (s: Shadow, found: bool, valid: bool) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		f := colon_fields(line)
		if len(f) < 2 || f[0] != user {
			continue
		}
		s = shadow_from_fields(f)
		valid = true
		days := [?]^i64{&s.lastchg, &s.min, &s.max, &s.warn, &s.inactive, &s.expire}
		for p, i in days {
			v := 2 + i < len(f) ? f[2 + i] : ""
			n, ok := parse_days(v)
			if !ok {
				valid = false
				n = NONE
			}
			p^ = n
		}
		if len(f) > 9 {
			valid = false
		}
		return s, true, valid
	}
	return {}, false, false
}

@(private = "file")
shadow_from_fields :: proc(f: []string) -> Shadow {
	return Shadow{name = f[0], hash = f[1], flag = len(f) > 8 ? f[8] : ""}
}

// format_shadow writes a Shadow back as one line, without the newline.
format_shadow :: proc(s: Shadow, allocator := context.temp_allocator) -> string {
	day :: proc(sb: ^strings.Builder, n: i64) {
		strings.write_byte(sb, ':')
		if n >= 0 {
			strings.write_i64(sb, n)
		}
	}
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, s.name)
	strings.write_byte(&sb, ':')
	strings.write_string(&sb, s.hash)
	day(&sb, s.lastchg)
	day(&sb, s.min)
	day(&sb, s.max)
	day(&sb, s.warn)
	day(&sb, s.inactive)
	day(&sb, s.expire)
	strings.write_byte(&sb, ':')
	strings.write_string(&sb, s.flag)
	return strings.to_string(sb)
}

// parse_groups returns every group `user` belongs to: the primary group from
// passwd first, then each group that lists the user as a member. This is
// initgroups(3) without NSS.
parse_groups :: proc(text: string, user: string, primary: u32, allocator := context.allocator) -> []u32 {
	out := make([dynamic]u32, allocator)
	append(&out, primary)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		f := colon_fields(line)
		if len(f) < 4 {
			continue
		}
		gid, ok := parse_id(f[2])
		if !ok {
			continue
		}
		for m in strings.split_iterator(&f[3], ",") {
			if strings.trim_space(m) == user {
				already := false
				for g in out {
					if g == gid {
						already = true
					}
				}
				if !already {
					append(&out, gid)
				}
				break
			}
		}
	}
	return out[:]
}

// group_id looks a group up by name.
group_id :: proc(text: string, name: string) -> (u32, bool) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		f := colon_fields(line)
		if len(f) >= 3 && f[0] == name {
			return parse_id(f[2])
		}
	}
	return 0, false
}

// read_text reads a whole database into the temp allocator.
read_text :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

// clone_account copies every string of `a` with `allocator`, so the account
// outlives the text it was parsed from.
clone_account :: proc(a: Account, allocator := context.allocator) -> Account {
	out := a
	out.name = strings.clone(a.name, allocator)
	out.passwd = strings.clone(a.passwd, allocator)
	out.gecos = strings.clone(a.gecos, allocator)
	out.home = strings.clone(a.home, allocator)
	out.shell = strings.clone(a.shell, allocator)
	return out
}

// valid_name is what a user name may look like before it is used to build a
// path or written to a log: the shadow-utils rule, plus a length limit.
valid_name :: proc(name: string) -> bool {
	if name == "" || len(name) > 32 || name[0] == '-' {
		return false
	}
	for c in transmute([]u8)name {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-', '.':
		case:
			return false
		}
	}
	return name != "." && name != ".."
}

// Credentials is what checking a password needs to know about an account:
// its passwd line and, when the hash lives there, its shadow line.
Credentials :: struct {
	acct:         Account,
	shadow:       Shadow,
	has_shadow:   bool,
	shadow_valid: bool,
}

// load_credentials reads `user` from passwd and shadow. Strings point into
// the temp allocator.
load_credentials :: proc(passwd_path, shadow_path, user: string) -> (c: Credentials, ok: bool) {
	ptext, pok := read_text(passwd_path)
	if !pok {
		return {}, false
	}
	acct, found := parse_passwd(ptext, user)
	if !found {
		return {}, false
	}
	c.acct = acct
	if stext, sok := read_text(shadow_path); sok {
		c.shadow, c.has_shadow, c.shadow_valid = parse_shadow_entry(stext, user)
	}
	return c, true
}

// stored_hash is the hash to check a password against: shadow's when passwd
// says "x", passwd's own otherwise. "" (never matches) when shadow should
// have it and does not, or when the shadow line is damaged.
stored_hash :: proc(c: Credentials) -> string {
	if c.acct.passwd != "x" {
		return c.acct.passwd
	}
	if !c.has_shadow || !c.shadow_valid {
		return ""
	}
	return c.shadow.hash
}

// DUMMY_HASH is what an unknown user's attempt is checked against, so it
// costs the same time as a real one.
DUMMY_HASH :: "$6$palmy$Bx42s72Foe9Q131t36Vl6afUo26skw/rGH.Gh2.1sxjLqcF/K29Hy0bvYDGyHaLynMyqorU41mNCDjhXf2q.T."

// check_password is the whole of "is this the password?". An unknown user,
// a locked account, a missing shadow entry and a wrong password all answer
// false the same way and in about the same time.
check_password :: proc(c: Credentials, found: bool, password: string) -> bool {
	if !found {
		_ = verify_password(password, DUMMY_HASH)
		return false
	}
	h := stored_hash(c)
	if h == "" || !is_hash(h) {
		_ = verify_password(password, DUMMY_HASH)
		return false
	}
	return verify_password(password, h)
}

// is_hash: a field verify_password would actually compute (not locked,
// not empty, a scheme we know).
is_hash :: proc(h: string) -> bool {
	return strings.has_prefix(h, "$6$")
}
