package sandbox

// The probe: what a confined process tries, to show the sandbox holds.
//
// Each Probe is one thing an assistant that had been talked into misbehaving
// might try, with the outcome the sandbox must produce. `run_probes` is
// called *inside* the sandbox (by `ai sandbox-probe`, which the self-test and
// cloud/assistant/e2e.sh start as a confined child) and reports, for each,
// what actually happened. A probe passes when the outcome matches: an
// allowed operation that is refused is as much a failure as a forbidden one
// that works, because a sandbox that refuses everything proves nothing.

import "base:intrinsics"
import "core:fmt"
import "core:strings"
import "core:sys/linux"

Probe_Kind :: enum u8 {
	Read, // open(path, O_RDONLY) and read a byte
	Write, // open(path, O_WRONLY|O_CREAT|O_TRUNC) and write a byte
	List, // open(path, O_DIRECTORY)
	Exec, // execve(path) in a child; success is the child running
	Tcp, // connect() to 127.0.0.1:port, or to `path` as an IPv4 literal
	Udp, // socket(AF_INET, SOCK_DGRAM)
	Unix, // socket(AF_UNIX, SOCK_STREAM)
	Ptrace, // ptrace(PTRACE_ATTACH, pid)
	Signal, // kill(pid, 0)
	Userns, // unshare(CLONE_NEWUSER)
	Io_Uring, // io_uring_setup
}

Probe :: struct {
	what:  string, // the sentence a report prints
	kind:  Probe_Kind,
	path:  string,
	port:  u16,
	pid:   int,
	allow: bool, // what the sandbox must do
}

Probe_Result :: struct {
	probe:  Probe,
	worked: bool,
	errno:  int,
	pass:   bool,
}

@(private) O_RDONLY :: 0
@(private) O_WRONLY :: 1
@(private) O_CREAT :: 0o100
@(private) O_TRUNC :: 0o1000
@(private) O_DIRECTORY :: 0o200000

@(private)
sys :: proc(nr: uintptr, args: ..uintptr) -> int {
	switch len(args) {
	case 0:
		return int(intrinsics.syscall(nr))
	case 1:
		return int(intrinsics.syscall(nr, args[0]))
	case 2:
		return int(intrinsics.syscall(nr, args[0], args[1]))
	case 3:
		return int(intrinsics.syscall(nr, args[0], args[1], args[2]))
	case:
		return int(intrinsics.syscall(nr, args[0], args[1], args[2], args[3]))
	}
}

@(private)
cstr :: proc(s: string) -> uintptr {
	return uintptr(rawptr(strings.clone_to_cstring(s, context.temp_allocator)))
}

@(private)
sockaddr_in :: proc(ip: [4]u8, port: u16) -> [16]u8 {
	a: [16]u8
	a[0] = 2 // AF_INET, little-endian u16
	a[2] = u8(port >> 8)
	a[3] = u8(port & 0xff)
	a[4], a[5], a[6], a[7] = ip[0], ip[1], ip[2], ip[3]
	return a
}

@(private)
parse_ip :: proc(s: string) -> (ip: [4]u8, ok: bool) {
	parts := strings.split(s, ".", context.temp_allocator)
	if len(parts) != 4 {
		return {}, false
	}
	for p, i in parts {
		n := 0
		for c in p {
			if c < '0' || c > '9' {return {}, false}
			n = n * 10 + int(c - '0')
		}
		if n > 255 {return {}, false}
		ip[i] = u8(n)
	}
	return ip, true
}

// try runs one probe and says whether the operation went through.
try :: proc(p: Probe) -> (worked: bool, errno: int) {
	switch p.kind {
	case .Read:
		fd := sys(linux.SYS_open, cstr(p.path), O_RDONLY, 0)
		if fd < 0 {return false, -fd}
		defer sys(linux.SYS_close, uintptr(fd))
		b: [1]u8
		n := sys(linux.SYS_read, uintptr(fd), uintptr(&b[0]), 1)
		return n >= 0, n < 0 ? -n : 0
	case .Write:
		fd := sys(linux.SYS_open, cstr(p.path), O_WRONLY | O_CREAT | O_TRUNC, 0o600)
		if fd < 0 {return false, -fd}
		defer sys(linux.SYS_close, uintptr(fd))
		b := [1]u8{'x'}
		n := sys(linux.SYS_write, uintptr(fd), uintptr(&b[0]), 1)
		return n == 1, n < 0 ? -n : 0
	case .List:
		fd := sys(linux.SYS_open, cstr(p.path), O_RDONLY | O_DIRECTORY, 0)
		if fd < 0 {return false, -fd}
		sys(linux.SYS_close, uintptr(fd))
		return true, 0
	case .Exec:
		pid := sys(linux.SYS_fork)
		if pid < 0 {return false, -pid}
		if pid == 0 {
			argv := [2]uintptr{cstr(p.path), 0}
			envp := [1]uintptr{0}
			r := sys(linux.SYS_execve, cstr(p.path), uintptr(&argv[0]), uintptr(&envp[0]))
			// 120 + errno, so the parent can tell a refused exec from a program
			// that ran and failed.
			sys(linux.SYS_exit_group, uintptr(120 + min(-r, 100)))
		}
		status: i32
		sys(linux.SYS_wait4, uintptr(pid), uintptr(&status), 0, 0)
		code := int((status >> 8) & 0xff)
		if code >= 120 {return false, code - 120}
		return true, 0
	case .Tcp:
		fd := sys(linux.SYS_socket, 2, 1, 0)
		if fd < 0 {return false, -fd}
		defer sys(linux.SYS_close, uintptr(fd))
		ip := [4]u8{127, 0, 0, 1}
		if p.path != "" {
			if v, ok := parse_ip(p.path); ok {ip = v}
		}
		a := sockaddr_in(ip, p.port)
		r := sys(linux.SYS_connect, uintptr(fd), uintptr(&a[0]), 16)
		return r == 0, r < 0 ? -r : 0
	case .Udp:
		fd := sys(linux.SYS_socket, 2, 2, 0)
		if fd < 0 {return false, -fd}
		sys(linux.SYS_close, uintptr(fd))
		return true, 0
	case .Unix:
		fd := sys(linux.SYS_socket, 1, 1, 0)
		if fd < 0 {return false, -fd}
		sys(linux.SYS_close, uintptr(fd))
		return true, 0
	case .Ptrace:
		r := sys(101, 16, uintptr(p.pid), 0, 0) // PTRACE_ATTACH
		if r == 0 {
			sys(101, 17, uintptr(p.pid), 0, 0) // PTRACE_DETACH
		}
		return r == 0, r < 0 ? -r : 0
	case .Signal:
		r := sys(linux.SYS_kill, uintptr(p.pid), 0)
		return r == 0, r < 0 ? -r : 0
	case .Userns:
		r := sys(272, 0x10000000)
		return r == 0, r < 0 ? -r : 0
	case .Io_Uring:
		params: [120]u8
		r := sys(425, 4, uintptr(&params[0]))
		if r >= 0 {sys(linux.SYS_close, uintptr(r))}
		return r >= 0, r < 0 ? -r : 0
	}
	return false, 0
}

run_probes :: proc(ps: []Probe, allocator := context.allocator) -> []Probe_Result {
	out := make([]Probe_Result, len(ps), allocator)
	for p, i in ps {
		worked, errno := try(p)
		out[i] = {probe = p, worked = worked, errno = errno, pass = worked == p.allow}
	}
	return out
}

errno_name :: proc(e: int) -> string {
	switch e {
	case 0:
		return ""
	case 1:
		return "EPERM"
	case 2:
		return "ENOENT"
	case 13:
		return "EACCES"
	case 111:
		return "ECONNREFUSED"
	case 3:
		return "ESRCH"
	case 22:
		return "EINVAL"
	case 38:
		return "ENOSYS"
	}
	return fmt.tprintf("errno %d", e)
}

// Probe_Setup is what the outside prepares for the probes: a home with two
// identities' folders and the person's token store, a tool directory, and
// listeners on an allowed and a forbidden port.
Probe_Setup :: struct {
	home:       string,
	own:        string, // the handle the sandbox is for
	other:      string, // another identity of the same person
	tool:       string, // an executable the sandbox may run
	open_port:  u16, // listening, allowed
	shut_port:  u16, // listening, not allowed
	parent_pid: int,
}

// standard_probes is the list the self-test and the e2e run. Every forbidden
// one names a real file or a real listener, so a refusal is the sandbox's
// doing and not a missing file's.
standard_probes :: proc(s: Probe_Setup, allocator := context.temp_allocator) -> []Probe {
	own := places_for(s.home, s.own, allocator)
	other := places_for(s.home, s.other, allocator)
	cloud := fmt.aprintf("%s/.local/share/palm/cloud", s.home, allocator = allocator)
	ps := make([dynamic]Probe, allocator)
	append(&ps,
		Probe{what = "reads its own identity's Drive folder", kind = .Read, path = fmt.aprintf("%s/invoice.txt", own.drive, allocator = allocator), allow = true},
		Probe{what = "reads its own identity's notes", kind = .Read, path = fmt.aprintf("%s/meeting.md", own.notes, allocator = allocator), allow = true},
		Probe{what = "writes in its own state directory", kind = .Write, path = fmt.aprintf("%s/scratch.txt", own.state, allocator = allocator), allow = true},
		Probe{what = "runs a tool binary", kind = .Exec, path = s.tool, allow = true},
		Probe{what = "connects to an allowed loopback port", kind = .Tcp, port = s.open_port, allow = true},
		Probe{what = "reads the other identity's Drive folder", kind = .Read, path = fmt.aprintf("%s/tax-return.txt", other.drive, allocator = allocator)},
		Probe{what = "lists the other identity's Drive folder", kind = .List, path = other.drive},
		Probe{what = "reads the other identity's notes", kind = .Read, path = fmt.aprintf("%s/diary.md", other.notes, allocator = allocator)},
		Probe{what = "reads the other identity's assistant state", kind = .Read, path = fmt.aprintf("%s/session.json", other.state, allocator = allocator)},
		Probe{what = "reads its own identity's search index", kind = .Read, path = fmt.aprintf("%s/manifest", own.index, allocator = allocator), allow = true},
		Probe{what = "reads the other identity's search index", kind = .Read, path = fmt.aprintf("%s/manifest", other.index, allocator = allocator)},
		Probe{what = "writes into its own search index (the daemon's, not its)", kind = .Write, path = fmt.aprintf("%s/manifest", own.index, allocator = allocator)},
		Probe{what = "reads the person's unscoped session", kind = .Read, path = fmt.aprintf("%s/session.json", cloud, allocator = allocator)},
		Probe{what = "reads this machine's session for the other identity", kind = .Read, path = fmt.aprintf("%s/scoped/%s.json", cloud, s.other, allocator = allocator)},
		Probe{what = "reads an SSH key", kind = .Read, path = fmt.aprintf("%s/.ssh/id_ed25519", s.home, allocator = allocator)},
		Probe{what = "lists the home directory", kind = .List, path = s.home},
		Probe{what = "writes into the home directory", kind = .Write, path = fmt.aprintf("%s/planted.sh", s.home, allocator = allocator)},
		Probe{what = "writes into the other identity's Drive folder", kind = .Write, path = fmt.aprintf("%s/planted.txt", other.drive, allocator = allocator)},
		Probe{what = "reads /etc/passwd", kind = .Read, path = "/etc/passwd"},
		Probe{what = "reads another process's environment", kind = .Read, path = fmt.aprintf("/proc/%d/environ", s.parent_pid, allocator = allocator)},
		Probe{what = "runs a shell", kind = .Exec, path = "/usr/bin/sh"},
		Probe{what = "runs curl", kind = .Exec, path = "/usr/bin/curl"},
		Probe{what = "connects to a loopback port it was not given", kind = .Tcp, port = s.shut_port},
		Probe{what = "connects to the internet (1.1.1.1:443)", kind = .Tcp, path = "1.1.1.1", port = 443},
		Probe{what = "opens a UDP socket (DNS, or any datagram out)", kind = .Udp},
		Probe{what = "opens a Unix socket (D-Bus, Wayland, X11)", kind = .Unix},
		Probe{what = "ptraces its parent", kind = .Ptrace, pid = s.parent_pid},
		Probe{what = "signals its parent", kind = .Signal, pid = s.parent_pid},
		Probe{what = "creates a user namespace", kind = .Userns},
		Probe{what = "sets up io_uring", kind = .Io_Uring},
	)
	return ps[:]
}
