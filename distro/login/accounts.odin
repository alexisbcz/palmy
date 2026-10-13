package login

// The three account databases: /etc/passwd, /etc/shadow, /etc/group.
//
// There is no NSS here and no PAM. Palmframe's accounts are flat files and
// palm-login reads them directly, the same way busybox's login does. The
// parsers take the text rather than a path so the selftest can feed them
// fixtures, and so --test mode can point at files the invoking user owns.
//
// Every file is re-read on every login attempt. They are small, and reading
// them fresh means a `passwd` run on the serial console takes effect at the
// next attempt without restarting anything.

import "core:os"
import "core:strconv"
import "core:strings"

Account :: struct {
	name:  string,
	uid:   u32,
	gid:   u32,
	gecos: string,
	home:  string,
	shell: string,
	// The password field of /etc/passwd. Almost always "x", meaning "look in
	// /etc/shadow"; anything else is a hash kept in passwd itself, which old
	// systems did and which is honoured for completeness.
	passwd: string,
}

Group :: struct {
	name:    string,
	gid:     u32,
	members: []string,
}

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
	passwd      = "/etc/passwd",
	shadow      = "/etc/shadow",
	group       = "/etc/group",
	locale_conf = "/etc/locale.conf",
	timezone    = "/etc/timezone",
	localtime   = "/etc/localtime",
}

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

// parse_passwd finds `user` in the text of an /etc/passwd. Strings in the
// result are slices of `text`.
parse_passwd :: proc(text: string, user: string) -> (a: Account, found: bool) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		f := colon_fields(line)
		if len(f) < 7 || f[0] != user {
			continue
		}
		uid, uok := parse_id(f[2])
		gid, gok := parse_id(f[3])
		if !uok || !gok {
			// A malformed line for the very user asked about: refuse, rather
			// than fall through to a later duplicate.
			return {}, false
		}
		return Account {
				name = f[0],
				passwd = f[1],
				uid = uid,
				gid = gid,
				gecos = f[4],
				home = f[5],
				shell = f[6],
			},
			true
	}
	return {}, false
}

// parse_shadow returns the hash field for `user` in the text of an
// /etc/shadow.
parse_shadow :: proc(text: string, user: string) -> (hash: string, found: bool) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		f := colon_fields(line)
		if len(f) < 2 || f[0] != user {
			continue
		}
		return f[1], true
	}
	return "", false
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

// group_id looks a group up by name, for chowning the socket to `greeter`.
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

// lookup_account reads passwd from disk and finds `user`. The strings are
// cloned with `allocator` so the account outlives the temp allocator.
lookup_account :: proc(paths: Paths, user: string, allocator := context.allocator) -> (a: Account, ok: bool) {
	text, rok := read_text(paths.passwd)
	if !rok {
		return {}, false
	}
	found: bool
	a, found = parse_passwd(text, user)
	if !found {
		return {}, false
	}
	a.name = strings.clone(a.name, allocator)
	a.passwd = strings.clone(a.passwd, allocator)
	a.gecos = strings.clone(a.gecos, allocator)
	a.home = strings.clone(a.home, allocator)
	a.shell = strings.clone(a.shell, allocator)
	return a, true
}

// authenticate is the whole of "is this the password?". An unknown user, a
// locked account, a missing shadow entry and a wrong password all answer
// false the same way, so the reply never tells a guesser which one it was.
authenticate :: proc(paths: Paths, user: string, password: string) -> bool {
	ptext, pok := read_text(paths.passwd)
	if !pok {
		return false
	}
	acct, found := parse_passwd(ptext, user)
	if !found {
		// Burn the same time a real check would, so an unknown name is not
		// told apart from a wrong password by how fast the answer comes.
		_ = verify_password(password, "$6$palmframe$x")
		return false
	}
	stored := acct.passwd
	if stored == "x" {
		stext, sok := read_text(paths.shadow)
		if !sok {
			return false
		}
		h, hfound := parse_shadow(stext, user)
		if !hfound {
			return false
		}
		stored = h
	}
	return verify_password(password, stored)
}
