package main

// /etc/passwd and /etc/group, read directly.
//
// A service runs as `user = <name>`, which means the uid, primary gid, home
// and shell from /etc/passwd, plus every group in /etc/group that lists the
// user — what initgroups(3) computes. palm-init is linked statically, and a
// static glibc cannot load NSS modules, so getpwnam/initgroups are not an
// option; and the files are simple enough that reading them is shorter than
// explaining why not.
//
//	passwd: name:password:uid:gid:gecos:home:shell
//	group:  name:password:gid:member,member,...

import "core:strconv"
import "core:strings"

Passwd_Entry :: struct {
	name:  string,
	uid:   u32,
	gid:   u32,
	home:  string,
	shell: string,
}

Group_Entry :: struct {
	name:    string,
	gid:     u32,
	members: []string,
}

parse_passwd :: proc(text: string, allocator := context.allocator) -> []Passwd_Entry {
	out := make([dynamic]Passwd_Entry, allocator)
	for line in strings.split_lines(text, allocator) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		f := strings.split(l, ":", allocator)
		if len(f) < 7 {continue}
		uid, ok1 := strconv.parse_uint(f[2], 10)
		gid, ok2 := strconv.parse_uint(f[3], 10)
		if !ok1 || !ok2 {continue}
		append(&out, Passwd_Entry{name = f[0], uid = u32(uid), gid = u32(gid), home = f[5], shell = f[6]})
	}
	return out[:]
}

parse_group :: proc(text: string, allocator := context.allocator) -> []Group_Entry {
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

find_user :: proc(users: []Passwd_Entry, name: string) -> (Passwd_Entry, bool) {
	for u in users {
		if u.name == name {return u, true}
	}
	return {}, false
}

find_group_gid :: proc(groups: []Group_Entry, name: string) -> (u32, bool) {
	for g in groups {
		if g.name == name {return g.gid, true}
	}
	return 0, false
}

// user_groups is initgroups(3): the primary gid first, then every group that
// names the user as a member, without duplicates.
user_groups :: proc(groups: []Group_Entry, name: string, primary: u32, allocator := context.allocator) -> []u32 {
	out := make([dynamic]u32, allocator)
	append(&out, primary)
	for g in groups {
		for m in g.members {
			if m != name {continue}
			dup := false
			for have in out {
				if have == g.gid {dup = true}
			}
			if !dup {append(&out, g.gid)}
		}
	}
	return out[:]
}
