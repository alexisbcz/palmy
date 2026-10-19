package doas

// `odin test distro/doas`: the policy file and the environment, without
// privileges. Built only by `odin test`; none of it is in the setuid binary.

import "core:strings"
import "core:testing"
import "../login/auth"

PASSWD :: "root:x:0:0:root:/root:/bin/sh\npalm:x:1000:1000:Palm:/home/palm:/bin/sh\nguest:x:1001:1001::/home/guest:/bin/sh\n"
GROUP :: "root:x:0:\nwheel:x:10:palm\npalm:x:1000:\nguest:x:1001:\n"

@(private = "file")
palm :: proc() -> Who {
	@(static) g := [2]u32{1000, 10}
	return Who{name = "palm", uid = 1000, groups = g[:]}
}
@(private = "file")
guest :: proc() -> Who {
	@(static) g := [1]u32{1001}
	return Who{name = "guest", uid = 1001, groups = g[:]}
}
@(private = "file")
root_acct :: proc() -> auth.Account {
	a, _ := auth.parse_passwd(PASSWD, "root")
	return a
}

@(private = "file")
decide :: proc(conf: string, who: Who, argv: []string, target := "root") -> (Rule, bool) {
	rules, err := parse_conf(conf)
	if err != "" {
		return {}, false
	}
	tgt, _ := auth.parse_passwd(PASSWD, target)
	path, _ := resolve(argv[0])
	return match_rules(rules[:], Request{who = who, target = tgt, cmd = argv[0], cmd_path = path, args = argv[1:]}, PASSWD, GROUP)
}

@(test)
test_parse_ok :: proc(t: ^testing.T) {
	conf := `# the default
permit :wheel
permit persist palm as root cmd /usr/bin/id
permit nopass setenv { FOO=bar -HOME LANG } guest cmd ls args -l "a b"
deny guest as root cmd rm  # trailing comment
permit keepenv nolog \
	palm
permit "pa\"lm"
`
	rules, err := parse_conf(conf)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(rules), 6)
	testing.expect_value(t, rules[0].ident, ":wheel")
	testing.expect(t, rules[1].persist && rules[1].target == "root" && rules[1].cmd == "/usr/bin/id")
	r := rules[2]
	testing.expect(t, r.nopass && len(r.setenv) == 3 && r.setenv[1] == "-HOME" && r.has_args && len(r.args) == 2 && r.args[1] == "a b")
	testing.expect(t, rules[3].action == .Deny && rules[3].cmd == "rm")
	testing.expect(t, rules[4].keepenv && rules[4].nolog && rules[4].ident == "palm" && rules[4].line == 6)
	testing.expect_value(t, rules[5].ident, `pa"lm`)
}

@(test)
test_parse_errors :: proc(t: ^testing.T) {
	bad := []string {
		"allow :wheel",
		"permit",
		"permit nopass",
		"deny nopass palm",
		"permit palm as",
		"permit palm cmd",
		"permit palm cmd ls extra",
		"permit setenv FOO=1 palm",
		"permit setenv { FOO=1 palm",
		"permit setenv { 1FOO=x } palm",
		"permit setenv { -FOO=x } palm",
		"permit nopass persist palm",
		`permit "palm`,
		"permit palm\x01",
		"permit :",
		"permit :wheel\npermit oops what",
	}
	for b in bad {
		_, err := parse_conf(b)
		testing.expectf(t, err != "", "accepted: %q", b)
	}
	// A keyword in quotes is a name, not a keyword.
	rules, err := parse_conf(`permit "nopass"`)
	testing.expect(t, err == "" && len(rules) == 1 && !rules[0].nopass && rules[0].ident == "nopass")
}

@(test)
test_match :: proc(t: ^testing.T) {
	_, ok := decide("permit :wheel", palm(), {"id"})
	testing.expect(t, ok)
	_, ok = decide("permit :wheel", guest(), {"id"})
	testing.expect(t, !ok)
	_, ok = decide("", palm(), {"id"})
	testing.expect(t, !ok)

	// The last match wins.
	r, m := decide("permit :wheel\ndeny palm cmd id", palm(), {"id"})
	testing.expect(t, m && r.action == .Deny)
	r, m = decide("deny palm cmd id\npermit :wheel", palm(), {"id"})
	testing.expect(t, m && r.action == .Permit)

	// as: only that target.
	_, ok = decide("permit palm as guest", palm(), {"id"}, "root")
	testing.expect(t, !ok)
	_, ok = decide("permit palm as guest", palm(), {"id"}, "guest")
	testing.expect(t, ok)

	// cmd and args. A bare name in a rule is the program the safe PATH
	// finds; a path elsewhere with the same name is not it.
	_, ok = decide("permit palm cmd id", palm(), {"id"})
	testing.expect(t, ok)
	_, ok = decide("permit palm cmd id", palm(), {"/usr/bin/id"})
	testing.expect(t, ok)
	_, ok = decide("permit palm cmd id", palm(), {"./id"})
	testing.expect(t, !ok)
	_, ok = decide("permit palm cmd id args -u", palm(), {"id", "-u"})
	testing.expect(t, ok)
	_, ok = decide("permit palm cmd id args -u", palm(), {"id", "-g"})
	testing.expect(t, !ok)
	_, ok = decide("permit palm cmd id args", palm(), {"id", "-u"})
	testing.expect(t, !ok)
	_, ok = decide("permit palm cmd id args", palm(), {"id"})
	testing.expect(t, ok)

	// Numeric identities.
	_, ok = decide("permit 1000", palm(), {"id"})
	testing.expect(t, ok)
	_, ok = decide("permit :10", palm(), {"id"})
	testing.expect(t, ok)
	_, ok = decide("permit :nosuchgroup", palm(), {"id"})
	testing.expect(t, !ok)
}

@(test)
test_env :: proc(t: ^testing.T) {
	caller := []string {
		"TERM=xterm-256color",
		"LANG=fr_FR.UTF-8",
		"LC_TIME=de_DE.UTF-8",
		"PATH=/home/palm/bin:/usr/bin",
		"HOME=/home/palm",
		"LD_PRELOAD=/tmp/evil.so",
		"FOO=bar",
		"TERM2=x",
		"WAYLAND_DISPLAY=wayland-1",
		"XDG_RUNTIME_DIR=/run/user/1000",
		"PYTHONPATH=/tmp",
	}
	has :: proc(env: []string, kv: string) -> bool {
		for e in env {
			if e == kv {
				return true
			}
		}
		return false
	}
	named :: proc(env: []string, name: string) -> bool {
		for e in env {
			if env_name(e) == name {
				return true
			}
		}
		return false
	}
	root := root_acct()
	env := build_env(caller, Rule{}, "palm", root)
	testing.expect(t, has(env, "TERM=xterm-256color") && has(env, "LANG=fr_FR.UTF-8") && has(env, "LC_TIME=de_DE.UTF-8"))
	testing.expect(t, has(env, "PATH=" + SAFE_PATH) && has(env, "HOME=/root") && has(env, "USER=root") && has(env, "DOAS_USER=palm"))
	testing.expect(t, has(env, "WAYLAND_DISPLAY=wayland-1"))
	testing.expect(t, !named(env, "LD_PRELOAD") && !named(env, "FOO") && !named(env, "TERM2") && !named(env, "XDG_RUNTIME_DIR"))

	// A kept variable whose value is a path is dropped.
	env = build_env([]string{"TERM=../../tmp/evil"}, Rule{}, "palm", root)
	testing.expect(t, !named(env, "TERM"))

	// keepenv keeps the rest, never the dangerous, and still resets PATH.
	env = build_env(caller, Rule{keepenv = true}, "palm", root)
	testing.expect(t, has(env, "FOO=bar") && has(env, "PATH=" + SAFE_PATH) && has(env, "HOME=/root"))
	testing.expect(t, !named(env, "LD_PRELOAD") && !named(env, "PYTHONPATH") && !named(env, "XDG_RUNTIME_DIR"))

	// setenv: set, copy, remove.
	r := Rule{}
	defer delete(r.setenv)
	append(&r.setenv, "EDITOR=vi", "FOO", "-LANG", "GREETING=$FOO", "MISSING=$NOPE")
	env = build_env(caller, r, "palm", root)
	testing.expect(t, has(env, "EDITOR=vi") && has(env, "FOO=bar") && has(env, "GREETING=bar"))
	testing.expect(t, !named(env, "LANG") && !named(env, "MISSING"))
	joined := strings.join(env, " ", context.temp_allocator)
	testing.expect(t, strings.count(joined, "PATH=") == 1, joined)
}
