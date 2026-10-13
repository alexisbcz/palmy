package palmd

// Who may ask: root, or a member of group wheel.
//
// The socket is 0666 -- anyone can connect -- and the decision is made per
// connection from SO_PEERCRED, which the kernel fills in at connect() with the
// peer's real credentials and which the peer cannot forge. Permissions on the
// socket file would do the same job only if wheel's membership were also the
// socket's group, and they would answer every refused client with a bare
// EACCES; checking here lets palmd say why, and log who tried.
//
// Membership is read from /etc/passwd and /etc/group on every connection,
// the way palm-init and palm-login read them (a static or NSS-less system has
// nothing else to ask), so editing /etc/group takes effect at the next
// connection with no restart. A user is in wheel if wheel's member list names
// them, or if wheel is their primary group in /etc/passwd. The peer's own gid
// from SO_PEERCRED is not consulted: the files are the policy.

import "base:intrinsics"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

WHEEL :: "wheel"

Peer :: struct {
	pid: i32,
	uid: u32,
	gid: u32,
}

// peer_cred reads SO_PEERCRED. core:sys/linux's getsockopt sizes the option
// by its pointer type rather than by struct ucred, so the call is made raw.
peer_cred :: proc(fd: linux.Fd) -> (p: Peer, ok: bool) {
	SOL_SOCKET :: 1
	SO_PEERCRED :: 17
	size := u32(size_of(Peer))
	ret := intrinsics.syscall(linux.SYS_getsockopt, uintptr(fd), SOL_SOCKET, SO_PEERCRED, uintptr(&p), uintptr(&size))
	return p, int(ret) == 0 && size == size_of(Peer)
}

Passwd_Entry :: struct {
	name: string,
	uid:  u32,
	gid:  u32,
}

Group_Entry :: struct {
	name:    string,
	gid:     u32,
	members: []string,
}

parse_passwd :: proc(text: string, allocator := context.temp_allocator) -> []Passwd_Entry {
	out := make([dynamic]Passwd_Entry, allocator)
	for line in strings.split_lines(text, allocator) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		f := strings.split(l, ":", allocator)
		if len(f) < 7 {continue}
		uid, ok1 := strconv.parse_uint(f[2], 10)
		gid, ok2 := strconv.parse_uint(f[3], 10)
		if !ok1 || !ok2 {continue}
		append(&out, Passwd_Entry{name = f[0], uid = u32(uid), gid = u32(gid)})
	}
	return out[:]
}

parse_group :: proc(text: string, allocator := context.temp_allocator) -> []Group_Entry {
	out := make([dynamic]Group_Entry, allocator)
	for line in strings.split_lines(text, allocator) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		f := strings.split(l, ":", allocator)
		if len(f) < 4 {continue}
		gid, ok := strconv.parse_uint(f[2], 10)
		if !ok {continue}
		members := make([dynamic]string, allocator)
		for m in strings.split(f[3], ",", allocator) {
			mm := strings.trim_space(m)
			if mm != "" {append(&members, mm)}
		}
		append(&out, Group_Entry{name = f[0], gid = u32(gid), members = members[:]})
	}
	return out[:]
}

// authorize is the decision, separated from the files so the selftest can put
// any passwd and group in front of it. `user` is the name the uid resolves to
// (or "" if none), for the log; `why` is what a refused client is told.
authorize :: proc(uid: u32, passwd_text, group_text: string) -> (allowed: bool, user: string, why: string) {
	if uid == 0 {
		return true, "root", ""
	}
	me: Maybe(Passwd_Entry)
	for e in parse_passwd(passwd_text) {
		if e.uid == uid {
			me = e
			break
		}
	}
	acct, known := me.?
	if !known {
		return false, "", "your uid is not in /etc/passwd"
	}
	for g in parse_group(group_text) {
		if g.name != WHEEL {continue}
		if acct.gid == g.gid {
			return true, acct.name, ""
		}
		for m in g.members {
			if m == acct.name {
				return true, acct.name, ""
			}
		}
		return false, acct.name, "only root and members of group wheel may change the system"
	}
	return false, acct.name, "there is no group wheel in /etc/group, so only root may change the system"
}
