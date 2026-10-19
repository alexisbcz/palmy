package doas

// Which rule applies, and what environment the command gets.

import "core:os"
import "core:strings"
import "../login/auth"

// SAFE_PATH is where commands are looked up, and the PATH they run with.
// Never the caller's PATH: `doas palm` must not find a `palm` the caller
// planted in ~/bin. Merged /usr makes /usr/bin hold the sbin programs too.
SAFE_PATH :: "/usr/local/bin:/usr/bin:/bin"

Who :: struct {
	name:   string,
	uid:    u32,
	groups: []u32, // the caller's real gid and supplementary groups
}

// resolve finds `name` as running it would: a path with '/' as given, a bare
// name in SAFE_PATH.
resolve :: proc(name: string, allocator := context.temp_allocator) -> (string, bool) {
	if name == "" {
		return "", false
	}
	if strings.index_byte(name, '/') >= 0 {
		return strings.clone(name, allocator), is_executable(name)
	}
	path := SAFE_PATH
	for dir in strings.split_iterator(&path, ":") {
		full := strings.concatenate({dir, "/", name}, allocator)
		if is_executable(full) {
			return full, true
		}
	}
	return "", false
}

is_executable :: proc(path: string) -> bool {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil || fi.type != .Regular {
		return false
	}
	return (fi.mode & {.Execute_User, .Execute_Group, .Execute_Other}) != {}
}

// match_ident: a user by name (or uid), or :group by name (or gid) among
// the caller's groups.
match_ident :: proc(ident: string, who: Who, group_text: string) -> bool {
	if strings.has_prefix(ident, ":") {
		g := ident[1:]
		gid, ok := auth.group_id(group_text, g)
		if !ok {
			gid, ok = parse_uint(g)
		}
		if !ok {
			return false
		}
		for have in who.groups {
			if have == gid {
				return true
			}
		}
		return false
	}
	if ident == who.name {
		return true
	}
	if n, ok := parse_uint(ident); ok {
		return n == who.uid
	}
	return false
}

parse_uint :: proc(s: string) -> (u32, bool) {
	if s == "" || len(s) > 10 {
		return 0, false
	}
	n: u64 = 0
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + u64(c - '0')
	}
	if n > u64(max(u32)) {
		return 0, false
	}
	return u32(n), true
}

// Request is what the caller asked for.
Request :: struct {
	who:         Who,
	target:      auth.Account,
	cmd:         string, // argv[0] as typed
	cmd_path:    string, // resolved
	args:        []string, // argv[1:]
}

// match_rules returns the last rule that matches, if any.
match_rules :: proc(rules: []Rule, req: Request, passwd_text, group_text: string) -> (Rule, bool) {
	found := false
	last: Rule
	for r in rules {
		if !match_ident(r.ident, req.who, group_text) {
			continue
		}
		if r.target != "" {
			t, ok := auth.parse_passwd(passwd_text, r.target)
			if !ok {
				n, nok := parse_uint(r.target)
				if !nok || n != req.target.uid {
					continue
				}
			} else if t.uid != req.target.uid {
				continue
			}
		}
		if r.cmd != "" {
			if r.cmd != req.cmd {
				rp, ok := resolve(r.cmd)
				if !ok || rp != req.cmd_path {
					continue
				}
			}
			if r.has_args {
				if len(r.args) != len(req.args) {
					continue
				}
				same := true
				for a, i in r.args {
					if a != req.args[i] {
						same = false
						break
					}
				}
				if !same {
					continue
				}
			}
		}
		last = r
		found = true
	}
	return last, found
}

// ---------------------------------------------------------------------------
// The environment
// ---------------------------------------------------------------------------

// Kept from the caller by default: what a terminal program needs to draw and
// speak the caller's language. Their values may not contain '/', so none
// can point a root program at a file (except the display names, which name
// a socket at most).
KEEP := [?]string{"TERM", "COLORTERM", "LANG", "LANGUAGE", "DISPLAY", "WAYLAND_DISPLAY"}

// Never kept, even with keepenv: what changes how a program loads or runs
// before its own code has a say.
DANGEROUS_PREFIXES := [?]string{"LD_", "MALLOC_", "GLIBC_", "PYTHON", "PERL", "RUBY", "NODE_", "BASH_FUNC_"}
DANGEROUS := [?]string {
	"GCONV_PATH", "GETCONF_DIR", "HOSTALIASES", "LOCALDOMAIN", "LOCPATH", "NLSPATH",
	"RES_OPTIONS", "RESOLV_HOST_CONF", "TMPDIR", "TZDIR", "ENV", "BASH_ENV", "IFS",
	"CDPATH", "PS4", "SHELLOPTS", "BASHOPTS", "GLOBIGNORE", "LESSOPEN", "LESSCLOSE",
	"EDITOR_ARGS", "XDG_RUNTIME_DIR",
}

env_name :: proc(kv: string) -> string {
	if eq := strings.index_byte(kv, '='); eq > 0 {
		return kv[:eq]
	}
	return ""
}

is_dangerous :: proc(name: string) -> bool {
	for p in DANGEROUS_PREFIXES {
		if strings.has_prefix(name, p) {
			return true
		}
	}
	for d in DANGEROUS {
		if name == d {
			return true
		}
	}
	return false
}

@(private = "file")
safe_value :: proc(name, value: string) -> bool {
	for c in transmute([]u8)value {
		if c < 0x20 || c == 0x7f {
			return false
		}
	}
	if name == "DISPLAY" || name == "WAYLAND_DISPLAY" {
		return true
	}
	return strings.index_byte(value, '/') < 0
}

Env :: struct {
	list: [dynamic]string,
}

env_set :: proc(e: ^Env, name, value: string) {
	kv := strings.concatenate({name, "=", value}, context.temp_allocator)
	for &have in e.list {
		if env_name(have) == name {
			have = kv
			return
		}
	}
	append(&e.list, kv)
}

env_unset :: proc(e: ^Env, name: string) {
	for i := len(e.list) - 1; i >= 0; i -= 1 {
		if env_name(e.list[i]) == name {
			ordered_remove(&e.list, i)
		}
	}
}

lookup :: proc(caller: []string, name: string) -> (string, bool) {
	for kv in caller {
		if env_name(kv) == name {
			return kv[len(name) + 1:], true
		}
	}
	return "", false
}

// build_env is the environment the command runs with: the kept variables
// (all of them but the dangerous ones with keepenv), then the target's own
// HOME, USER, LOGNAME, SHELL and the safe PATH, then DOAS_USER, then the
// rule's setenv.
build_env :: proc(caller: []string, rule: Rule, me: string, target: auth.Account) -> []string {
	e := Env{list = make([dynamic]string, context.temp_allocator)}
	if rule.keepenv {
		for kv in caller {
			name := env_name(kv)
			if name == "" || is_dangerous(name) {
				continue
			}
			env_set(&e, name, kv[len(name) + 1:])
		}
	} else {
		for kv in caller {
			name := env_name(kv)
			if name == "" {
				continue
			}
			keep := strings.has_prefix(name, "LC_") && valid_env_name(name)
			for k in KEEP {
				if name == k {
					keep = true
				}
			}
			if keep && safe_value(name, kv[len(name) + 1:]) {
				env_set(&e, name, kv[len(name) + 1:])
			}
		}
	}
	shell := target.shell == "" ? "/bin/sh" : target.shell
	env_set(&e, "HOME", target.home)
	env_set(&e, "USER", target.name)
	env_set(&e, "LOGNAME", target.name)
	env_set(&e, "SHELL", shell)
	env_set(&e, "PATH", SAFE_PATH)
	env_set(&e, "DOAS_USER", me)
	for s in rule.setenv {
		switch {
		case strings.has_prefix(s, "-"):
			env_unset(&e, s[1:])
		case strings.index_byte(s, '=') > 0:
			name := env_name(s)
			value := s[len(name) + 1:]
			if strings.has_prefix(value, "$") {
				if v, ok := lookup(caller, value[1:]); ok {
					env_set(&e, name, v)
				} else {
					env_unset(&e, name)
				}
			} else {
				env_set(&e, name, value)
			}
		case:
			if v, ok := lookup(caller, s); ok {
				env_set(&e, s, v)
			}
		}
	}
	return e.list[:]
}
