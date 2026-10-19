// palm-sandbox-check — the sandbox, tested from the inside.
//
// Builds a throwaway home with two identities (their Drive and Notes
// folders, the person's token store, an SSH key), listens on two loopback
// ports, then forks a child that confines itself to the first identity with
// exactly the policy the assistant uses and runs sandbox.standard_probes.
// Prints one line per probe (or JSON with --json) and exits 0 only if every
// probe came out as the sandbox requires.
//
//	odin build cloud/assistant/sandbox/check -out:palm-sandbox-check
//	./palm-sandbox-check [--json] [--keep]
package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import sb "../"

write :: proc(path, text: string) {
	dir := path[:strings.last_index_byte(path, '/')]
	os.make_directory_all(dir, os.perm_number(0o700))
	_ = os.write_entire_file(path, transmute([]u8)text, os.perm_number(0o600))
}

listen_on :: proc() -> (fd: int, port: u16) {
	fd = int(intrinsics.syscall(linux.SYS_socket, 2, 1, 0))
	a: [16]u8
	a[0] = 2
	a[4], a[5], a[6], a[7] = 127, 0, 0, 1
	intrinsics.syscall(linux.SYS_bind, uintptr(fd), uintptr(&a[0]), 16)
	intrinsics.syscall(linux.SYS_listen, uintptr(fd), 8)
	got: [16]u8
	n := u32(16)
	intrinsics.syscall(linux.SYS_getsockname, uintptr(fd), uintptr(&got[0]), uintptr(&n))
	port = u16(got[2]) << 8 | u16(got[3])
	return
}

main :: proc() {
	// Run as the stand-in tool (see below): succeed and do nothing.
	if strings.has_suffix(os.args[0], "/tool") {
		os.exit(0)
	}
	as_json, keep := false, false
	for a in os.args[1:] {
		if a == "--json" {as_json = true}
		if a == "--keep" {keep = true}
	}
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {base = "/tmp"}
	home := fmt.tprintf("%s/palm-sandbox-check.%d", base, os.get_pid())
	own, other := "camille.roux", "camille"
	op := sb.places_for(home, own)
	xp := sb.places_for(home, other)
	sb.ensure_places(op)
	sb.ensure_places(xp)
	write(fmt.tprintf("%s/invoice.txt", op.drive), "Halden invoice, September\n")
	write(fmt.tprintf("%s/meeting.md", op.notes), "# Roadmap review\n")
	write(fmt.tprintf("%s/tax-return.txt", xp.drive), "PERSONAL-CANARY-7731\n")
	write(fmt.tprintf("%s/diary.md", xp.notes), "PERSONAL-CANARY-7731\n")
	write(fmt.tprintf("%s/session.json", xp.state), "{\"refresh_token\":\"personal-assistant\"}\n")
	write(fmt.tprintf("%s/.local/share/palm/cloud/session.json", home), "{\"refresh_token\":\"the-person\"}\n")
	write(fmt.tprintf("%s/.local/share/palm/cloud/scoped/%s.json", home, other), "{\"refresh_token\":\"personal-device\"}\n")
	write(fmt.tprintf("%s/.ssh/id_ed25519", home), "-----BEGIN OPENSSH PRIVATE KEY-----\n")

	// A tool directory with one binary in it: this program itself, run with
	// --exit-0, stands in for a tool.
	tools := fmt.tprintf("%s/tools", home)
	os.make_directory_all(tools, os.perm_number(0o700))
	self, _ := os.get_executable_path(context.temp_allocator)
	tool := fmt.tprintf("%s/tool", tools)
	data, _ := os.read_entire_file_from_path(self, context.temp_allocator)
	_ = os.write_entire_file(tool, data, os.perm_number(0o700))

	_, open_port := listen_on()
	_, shut_port := listen_on()

	setup := sb.Probe_Setup {
		home       = home,
		own        = own,
		other      = other,
		tool       = tool,
		open_port  = open_port,
		shut_port  = shut_port,
		parent_pid = os.get_pid(),
	}
	probes := sb.standard_probes(setup)

	// The child reports through a pipe: one line per probe, "pass worked errno".
	fds: [2]i32
	intrinsics.syscall(linux.SYS_pipe2, uintptr(&fds[0]), 0)
	pid := int(intrinsics.syscall(linux.SYS_fork))
	if pid == 0 {
		intrinsics.syscall(linux.SYS_close, uintptr(fds[0]))
		pol := sb.policy_for(op, {tools}, {open_port})
		rep, err := sb.enter(pol)
		if err != "" {
			msg := fmt.tprintf("ERR %s\n", err)
			intrinsics.syscall(linux.SYS_write, uintptr(fds[1]), uintptr(raw_data(msg)), uintptr(len(msg)))
			intrinsics.syscall(linux.SYS_exit_group, 3)
		}
		head := fmt.tprintf("ABI %d %d %d %v %v\n", rep.abi, rep.fs_rules, rep.net_rules, rep.scoped, rep.seccomp)
		intrinsics.syscall(linux.SYS_write, uintptr(fds[1]), uintptr(raw_data(head)), uintptr(len(head)))
		for r in sb.run_probes(probes, context.temp_allocator) {
			line := fmt.tprintf("%v %v %d\n", r.pass, r.worked, r.errno)
			intrinsics.syscall(linux.SYS_write, uintptr(fds[1]), uintptr(raw_data(line)), uintptr(len(line)))
		}
		intrinsics.syscall(linux.SYS_exit_group, 0)
	}
	intrinsics.syscall(linux.SYS_close, uintptr(fds[1]))
	out := make([dynamic]u8, context.temp_allocator)
	buf: [4096]u8
	for {
		n := int(intrinsics.syscall(linux.SYS_read, uintptr(fds[0]), uintptr(&buf[0]), len(buf)))
		if n <= 0 {break}
		append(&out, ..buf[:n])
	}
	status: i32
	intrinsics.syscall(linux.SYS_wait4, uintptr(pid), uintptr(&status), 0, 0)

	lines := strings.split_lines(strings.trim_space(string(out[:])), context.temp_allocator)
	failed := 0
	if len(lines) == 0 || strings.has_prefix(lines[0], "ERR") {
		fmt.eprintfln("palm-sandbox-check: %s", len(lines) > 0 ? lines[0] : "the child said nothing")
		os.exit(1)
	}
	header := strings.fields(lines[0], context.temp_allocator)
	sb_json := strings.builder_make(context.temp_allocator)
	if as_json {
		fmt.sbprintf(&sb_json, "{{\"landlock_abi\":%s,\"fs_rules\":%s,\"net_rules\":%s,\"scoped\":%s,\"seccomp\":%s,\"probes\":[",
			header[1], header[2], header[3], header[4], header[5])
	} else {
		fmt.printfln("sandbox for %s: Landlock ABI %s, %s path rules, %s port rule(s), scoped %s, seccomp %s",
			own, header[1], header[2], header[3], header[4], header[5])
	}
	for p, i in probes {
		pass, worked := false, false
		errno := 0
		if i + 1 < len(lines) {
			f := strings.fields(lines[i + 1], context.temp_allocator)
			if len(f) == 3 {
				pass = f[0] == "true"
				worked = f[1] == "true"
				for c in f[2] {errno = errno * 10 + int(c - '0')}
			}
		}
		if !pass {failed += 1}
		outcome := worked ? "allowed" : fmt.tprintf("refused (%s)", sb.errno_name(errno))
		if as_json {
			fmt.sbprintf(&sb_json, "%s{{\"what\":%q,\"must\":%q,\"outcome\":%q,\"pass\":%v}}",
				i > 0 ? "," : "", p.what, p.allow ? "allow" : "refuse", outcome, pass)
		} else {
			fmt.printfln("%s  %s: %s", pass ? "ok  " : "FAIL", p.what, outcome)
		}
	}
	if as_json {
		fmt.sbprintf(&sb_json, "],\"passed\":%d,\"failed\":%d}}", len(probes) - failed, failed)
		fmt.println(strings.to_string(sb_json))
	} else {
		fmt.printfln("%d/%d probes as required", len(probes) - failed, len(probes))
	}
	if !keep {
		os.remove_all(home)
	}
	os.exit(failed == 0 ? 0 : 1)
}
