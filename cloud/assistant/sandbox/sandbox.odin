// Package sandbox confines the assistant's process to one identity.
//
// The assistant for identity X runs as the person's own Unix user, so
// without this it could read everything that user can: the other
// identities' Drive and Notes folders, the person's unscoped session in
// ~/.local/share/palm/cloud/session.json (which would undo every RLS policy
// in one read), SSH keys, the browser profile. And it could connect anywhere.
// The database scope (cloud/CONTRACT.md) says what its *token* may reach;
// this says what its *process* may reach, and the two together are the claim
// cloud/docs/assistant.md makes.
//
// Four layers, applied in this order by `enter`, all inherited by every
// program the assistant runs afterwards (the tool binaries):
//
//  1. PR_SET_NO_NEW_PRIVS, so no setuid binary can lift it out, and
//     PR_SET_DUMPABLE 0, so another process of the same user cannot ptrace
//     it or read its memory (and with it the delegated token).
//  2. Landlock, file system: nothing is readable, writable or executable
//     except the paths in the Policy. Read-only for the system libraries,
//     execute for the tool binaries alone, read-write for X's own data
//     directories and the assistant's state directory for X. Nothing else of
//     $HOME exists for it.
//  3. Landlock, network (ABI 4+): TCP connect only to the listed ports on
//     any address — in practice the loopback cloud gateway, ollama, and the
//     DAV server — and no TCP bind at all. Landlock cannot name hosts, only
//     ports; cloud/docs/assistant.md says what that leaves open.
//     Landlock scopes (ABI 6+): no connecting to abstract Unix sockets made
//     outside the sandbox, and no signalling processes outside it.
//  4. seccomp: no Unix-domain sockets at all (Landlock does not govern
//     connect() to a pathname socket, and the session D-Bus would otherwise be
//     one systemd-run away from an unconfined process), no UDP or raw
//     sockets (Landlock's network rules are TCP only; this closes DNS and
//     UDP as a way out), no io_uring (which could do the same operations
//     without the syscalls this filter sees), no ptrace, no
//     process_vm_readv/writev, no bpf, no perf_event_open, no keyring, no
//     user namespaces, no mount, no TIOCSTI.
//
// `enter` fails closed: if any layer cannot be applied, it returns an error
// and the caller must exit rather than run unconfined.
package sandbox

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

// ---------------------------------------------------------------------------
// The policy
// ---------------------------------------------------------------------------

Policy :: struct {
	read_only:   []string, // files and directories: read
	execute:     []string, // files and directories: read and execute
	read_write:  []string, // directories: everything but device nodes
	devices:     []string, // device files: read and write (/dev/null, /dev/urandom)
	tcp_connect: []u16, // the only TCP ports it may connect to
}

Report :: struct {
	abi:          int, // the Landlock ABI the kernel speaks
	fs_rules:     int,
	net_rules:    int,
	scoped:       bool, // abstract sockets and signals scoped (ABI 6+)
	seccomp:      bool,
	skipped:      [dynamic]string, // policy paths that did not exist
}

// ---------------------------------------------------------------------------
// Landlock, from include/uapi/linux/landlock.h
// ---------------------------------------------------------------------------

@(private) SYS_LANDLOCK_CREATE_RULESET :: 444
@(private) SYS_LANDLOCK_ADD_RULE :: 445
@(private) SYS_LANDLOCK_RESTRICT_SELF :: 446 // the same on every architecture

@(private) LANDLOCK_CREATE_RULESET_VERSION :: 1
@(private) LANDLOCK_RULE_PATH_BENEATH :: 1
@(private) LANDLOCK_RULE_NET_PORT :: 2

FS_EXECUTE :: u64(1) << 0
FS_WRITE_FILE :: u64(1) << 1
FS_READ_FILE :: u64(1) << 2
FS_READ_DIR :: u64(1) << 3
FS_REMOVE_DIR :: u64(1) << 4
FS_REMOVE_FILE :: u64(1) << 5
FS_MAKE_CHAR :: u64(1) << 6
FS_MAKE_DIR :: u64(1) << 7
FS_MAKE_REG :: u64(1) << 8
FS_MAKE_SOCK :: u64(1) << 9
FS_MAKE_FIFO :: u64(1) << 10
FS_MAKE_BLOCK :: u64(1) << 11
FS_MAKE_SYM :: u64(1) << 12
FS_REFER :: u64(1) << 13 // ABI 2
FS_TRUNCATE :: u64(1) << 14 // ABI 3
FS_IOCTL_DEV :: u64(1) << 15 // ABI 5

NET_BIND_TCP :: u64(1) << 0 // ABI 4
NET_CONNECT_TCP :: u64(1) << 1 // ABI 4

SCOPE_ABSTRACT_UNIX_SOCKET :: u64(1) << 0 // ABI 6
SCOPE_SIGNAL :: u64(1) << 1 // ABI 6

@(private)
Ruleset_Attr :: struct #packed {
	handled_access_fs:  u64,
	handled_access_net: u64,
	scoped:             u64,
}

@(private)
Path_Beneath_Attr :: struct #packed {
	allowed_access: u64,
	parent_fd:      i32,
}

@(private)
Net_Port_Attr :: struct #packed {
	allowed_access: u64,
	port:           u64,
}

// The rights a rule may grant on a regular file; anything else is EINVAL.
@(private)
FILE_RIGHTS :: FS_EXECUTE | FS_WRITE_FILE | FS_READ_FILE | FS_TRUNCATE | FS_IOCTL_DEV

// fs_handled is every file-system right the running ABI knows. Handling all
// of them means anything not granted below is denied.
@(private)
fs_handled :: proc(abi: int) -> u64 {
	all := (FS_MAKE_SYM << 1) - 1 // EXECUTE .. MAKE_SYM, ABI 1
	if abi >= 2 {all |= FS_REFER}
	if abi >= 3 {all |= FS_TRUNCATE}
	if abi >= 5 {all |= FS_IOCTL_DEV}
	return all
}

// landlock_abi asks the kernel which Landlock it speaks: 0 when it has none
// (not built, or not in the `lsm=` list).
landlock_abi :: proc() -> int {
	r := intrinsics.syscall(SYS_LANDLOCK_CREATE_RULESET, 0, 0, LANDLOCK_CREATE_RULESET_VERSION)
	n := int(r)
	return n < 0 ? 0 : n
}

@(private)
O_PATH :: 0o10000000
@(private)
O_CLOEXEC :: 0o2000000
// openat with this resolves a relative path as open would. There is no
// SYS_open on arm64 (nor riscv64): every open in this package is an openat.
AT_FDCWD :: ~uintptr(99) // -100

@(private)
add_path :: proc(ruleset: int, path: string, want: u64, abi: int, rep: ^Report) -> string {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd := int(intrinsics.syscall(linux.SYS_openat, AT_FDCWD, uintptr(rawptr(cpath)), O_PATH | O_CLOEXEC, 0))
	if fd < 0 {
		append(&rep.skipped, strings.clone(path))
		return ""
	}
	defer intrinsics.syscall(linux.SYS_close, uintptr(fd))
	access := want & fs_handled(abi)
	st: linux.Stat
	if linux.fstat(linux.Fd(fd), &st) == .NONE && !linux.S_ISDIR(st.mode) {
		access &= FILE_RIGHTS
	}
	attr := Path_Beneath_Attr{allowed_access = access, parent_fd = i32(fd)}
	r := int(intrinsics.syscall(SYS_LANDLOCK_ADD_RULE, uintptr(ruleset), LANDLOCK_RULE_PATH_BENEATH, uintptr(&attr), 0))
	if r < 0 {
		return fmt.tprintf("landlock_add_rule(%s): errno %d", path, -r)
	}
	rep.fs_rules += 1
	return ""
}

// ---------------------------------------------------------------------------
// seccomp
// ---------------------------------------------------------------------------

@(private)
Sock_Filter :: struct {
	code: u16,
	jt:   u8,
	jf:   u8,
	k:    u32,
}

@(private)
Sock_Fprog :: struct {
	len:    u16,
	filter: [^]Sock_Filter,
}

@(private) BPF_LD_W_ABS :: 0x20 // BPF_LD | BPF_W | BPF_ABS
@(private) BPF_JEQ_K :: 0x15 // BPF_JMP | BPF_JEQ | BPF_K
@(private) BPF_JSET_K :: 0x45 // BPF_JMP | BPF_JSET | BPF_K
@(private) BPF_RET_K :: 0x06
@(private) BPF_ALU_AND_K :: 0x54 // BPF_ALU | BPF_AND | BPF_K

@(private) SECCOMP_RET_ALLOW :: 0x7fff0000
@(private) SECCOMP_RET_ERRNO :: 0x00050000
@(private) SECCOMP_RET_KILL_PROCESS :: 0x80000000
@(private) AUDIT_ARCH_X86_64 :: 0xc000003e
@(private) AUDIT_ARCH_AARCH64 :: 0xc00000b7

// AUDIT_ARCH is the one architecture the filter lets through. The syscall
// numbers below come from core:sys/linux, which defines them per
// architecture, so the same list means the same calls on both.
when ODIN_ARCH == .amd64 {
	@(private) AUDIT_ARCH :: AUDIT_ARCH_X86_64
} else when ODIN_ARCH == .arm64 {
	@(private) AUDIT_ARCH :: AUDIT_ARCH_AARCH64
} else {
	@(private) AUDIT_ARCH :: 0 // enter refuses before the filter is built
}
@(private) EPERM :: 1

// Offsets into struct seccomp_data.
@(private) OFF_NR :: 0
@(private) OFF_ARCH :: 4
@(private) OFF_ARG0 :: 16
@(private) OFF_ARG1 :: 24

// The syscalls refused outright, with EPERM so a program that probes for one
// degrades instead of dying.
@(private)
DENIED := [?]u32 {
	u32(linux.SYS_ptrace),
	u32(linux.SYS_process_vm_readv),
	u32(linux.SYS_process_vm_writev),
	u32(linux.SYS_perf_event_open),
	u32(linux.SYS_bpf),
	u32(linux.SYS_userfaultfd),
	u32(linux.SYS_add_key),
	u32(linux.SYS_request_key),
	u32(linux.SYS_keyctl),
	u32(linux.SYS_unshare),
	u32(linux.SYS_setns),
	u32(linux.SYS_mount),
	u32(linux.SYS_umount2),
	u32(linux.SYS_pivot_root),
	u32(linux.SYS_chroot),
	u32(linux.SYS_io_uring_setup),
	u32(linux.SYS_io_uring_enter),
	u32(linux.SYS_io_uring_register),
	u32(linux.SYS_open_tree),
	u32(linux.SYS_move_mount),
	u32(linux.SYS_fsopen),
	u32(linux.SYS_fsmount),
	u32(linux.SYS_kexec_load),
	u32(linux.SYS_kexec_file_load),
	u32(linux.SYS_init_module),
	u32(linux.SYS_finit_module),
	u32(linux.SYS_clone3), // it takes its flags in a struct this filter cannot
	                       // read, so a new user namespace could hide there.
	                       // glibc falls back to clone.
}

@(private) SYS_SOCKET :: u32(linux.SYS_socket)
@(private) SYS_CLONE :: u32(linux.SYS_clone)
@(private) SYS_IOCTL :: u32(linux.SYS_ioctl)
@(private) AF_INET :: 2
@(private) AF_INET6 :: 10
@(private) SOCK_STREAM :: 1
@(private) SOCK_TYPE_MASK :: 0xf
@(private) CLONE_NEWUSER :: 0x10000000
@(private) TIOCSTI :: 0x5412

@(private)
stmt :: proc(code: u16, k: u32) -> Sock_Filter {
	return {code = code, k = k}
}

@(private)
jump :: proc(code: u16, k: u32, jt, jf: u8) -> Sock_Filter {
	return {code = code, jt = jt, jf = jf, k = k}
}

// seccomp_program builds the filter. Read it top to bottom: the architecture
// check, the outright denials, then three syscalls whose arguments matter.
@(private)
seccomp_program :: proc(allocator := context.temp_allocator) -> [dynamic]Sock_Filter {
	f := make([dynamic]Sock_Filter, allocator)
	deny := u32(SECCOMP_RET_ERRNO | EPERM)

	// Anything not this program's architecture (an i386 syscall through
	// int 0x80 on x86-64, an AArch32 one on arm64: other numbers) is killed
	// rather than mis-filtered.
	append(&f, stmt(BPF_LD_W_ABS, OFF_ARCH))
	append(&f, jump(BPF_JEQ_K, AUDIT_ARCH, 1, 0))
	append(&f, stmt(BPF_RET_K, SECCOMP_RET_KILL_PROCESS))
	// The x32 ABI sets bit 30 of the number; refuse it too. (No arm64
	// syscall has it set, so there the check costs two instructions.)
	append(&f, stmt(BPF_LD_W_ABS, OFF_NR))
	append(&f, jump(BPF_JSET_K, 0x40000000, 0, 1))
	append(&f, stmt(BPF_RET_K, deny))

	for nr in DENIED {
		append(&f, jump(BPF_JEQ_K, nr, 0, 1))
		append(&f, stmt(BPF_RET_K, deny))
	}

	// socket(domain, type, ...): only AF_INET / AF_INET6 with SOCK_STREAM.
	append(&f, jump(BPF_JEQ_K, SYS_SOCKET, 0, 9))
	append(&f, stmt(BPF_LD_W_ABS, OFF_ARG0))
	append(&f, jump(BPF_JEQ_K, AF_INET, 2, 0))
	append(&f, jump(BPF_JEQ_K, AF_INET6, 1, 0))
	append(&f, stmt(BPF_RET_K, deny))
	append(&f, stmt(BPF_LD_W_ABS, OFF_ARG1))
	append(&f, stmt(BPF_ALU_AND_K, SOCK_TYPE_MASK))
	append(&f, jump(BPF_JEQ_K, SOCK_STREAM, 1, 0))
	append(&f, stmt(BPF_RET_K, deny))
	append(&f, stmt(BPF_RET_K, SECCOMP_RET_ALLOW))

	// clone(flags, ...): no new user namespace.
	append(&f, jump(BPF_JEQ_K, SYS_CLONE, 0, 4))
	append(&f, stmt(BPF_LD_W_ABS, OFF_ARG0))
	append(&f, jump(BPF_JSET_K, CLONE_NEWUSER, 0, 1))
	append(&f, stmt(BPF_RET_K, deny))
	append(&f, stmt(BPF_RET_K, SECCOMP_RET_ALLOW))

	// ioctl(fd, TIOCSTI, ...): no typing into a terminal it inherited.
	append(&f, jump(BPF_JEQ_K, SYS_IOCTL, 0, 4))
	append(&f, stmt(BPF_LD_W_ABS, OFF_ARG1))
	append(&f, jump(BPF_JEQ_K, TIOCSTI, 0, 1))
	append(&f, stmt(BPF_RET_K, deny))
	append(&f, stmt(BPF_RET_K, SECCOMP_RET_ALLOW))

	append(&f, stmt(BPF_RET_K, SECCOMP_RET_ALLOW))
	return f
}

// ---------------------------------------------------------------------------
// Entering
// ---------------------------------------------------------------------------

@(private) PR_SET_DUMPABLE :: 4
@(private) PR_SET_NO_NEW_PRIVS :: 38
@(private) SECCOMP_SET_MODE_FILTER :: 1
@(private) SECCOMP_FILTER_FLAG_TSYNC :: 1

// MIN_ABI is the oldest Landlock this will run under. ABI 4 is the first with
// network rules; without them the assistant could connect anywhere, and that
// is not a sandbox worth the name.
MIN_ABI :: 4

// enter confines the calling process, irreversibly. Call it before any
// thread is started. On error the process is in an unknown, partly confined
// state and must exit.
enter :: proc(p: Policy) -> (rep: Report, err: string) {
	rep.skipped = make([dynamic]string)
	if ODIN_OS != .Linux || (ODIN_ARCH != .amd64 && ODIN_ARCH != .arm64) {
		return rep, "the sandbox is implemented for Linux on x86-64 and arm64 only"
	}
	abi := landlock_abi()
	rep.abi = abi
	if abi < MIN_ABI {
		return rep, fmt.tprintf("Landlock ABI %d is too old (need %d, for network rules); refusing to run unconfined", abi, MIN_ABI)
	}

	if r := int(intrinsics.syscall(linux.SYS_prctl, PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)); r < 0 {
		return rep, fmt.tprintf("PR_SET_NO_NEW_PRIVS: errno %d", -r)
	}
	if r := int(intrinsics.syscall(linux.SYS_prctl, PR_SET_DUMPABLE, 0, 0, 0, 0)); r < 0 {
		return rep, fmt.tprintf("PR_SET_DUMPABLE: errno %d", -r)
	}

	attr := Ruleset_Attr {
		handled_access_fs  = fs_handled(abi),
		handled_access_net = NET_BIND_TCP | NET_CONNECT_TCP,
	}
	attr_size := size_of(Ruleset_Attr)
	if abi >= 6 {
		attr.scoped = SCOPE_ABSTRACT_UNIX_SOCKET | SCOPE_SIGNAL
		rep.scoped = true
	} else {
		attr_size = 16 // the struct before `scoped` existed
	}
	ruleset := int(intrinsics.syscall(SYS_LANDLOCK_CREATE_RULESET, uintptr(&attr), uintptr(attr_size), 0))
	if ruleset < 0 {
		return rep, fmt.tprintf("landlock_create_ruleset: errno %d", -ruleset)
	}
	defer intrinsics.syscall(linux.SYS_close, uintptr(ruleset))

	READ :: FS_READ_FILE | FS_READ_DIR
	RW :: FS_WRITE_FILE | FS_READ_FILE | FS_READ_DIR | FS_REMOVE_DIR | FS_REMOVE_FILE |
		FS_MAKE_DIR | FS_MAKE_REG | FS_MAKE_SYM | FS_MAKE_FIFO | FS_REFER | FS_TRUNCATE
	for path in p.read_only {
		if e := add_path(ruleset, path, READ, abi, &rep); e != "" {return rep, e}
	}
	for path in p.execute {
		if e := add_path(ruleset, path, READ | FS_EXECUTE, abi, &rep); e != "" {return rep, e}
	}
	for path in p.read_write {
		if e := add_path(ruleset, path, RW, abi, &rep); e != "" {return rep, e}
	}
	for path in p.devices {
		if e := add_path(ruleset, path, FS_READ_FILE | FS_WRITE_FILE, abi, &rep); e != "" {return rep, e}
	}
	for port in p.tcp_connect {
		na := Net_Port_Attr{allowed_access = NET_CONNECT_TCP, port = u64(port)}
		r := int(intrinsics.syscall(SYS_LANDLOCK_ADD_RULE, uintptr(ruleset), LANDLOCK_RULE_NET_PORT, uintptr(&na), 0))
		if r < 0 {
			return rep, fmt.tprintf("landlock_add_rule(port %d): errno %d", port, -r)
		}
		rep.net_rules += 1
	}
	if r := int(intrinsics.syscall(SYS_LANDLOCK_RESTRICT_SELF, uintptr(ruleset), 0)); r < 0 {
		return rep, fmt.tprintf("landlock_restrict_self: errno %d", -r)
	}

	prog := seccomp_program()
	fprog := Sock_Fprog{len = u16(len(prog)), filter = raw_data(prog)}
	if r := int(intrinsics.syscall(linux.SYS_seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC, uintptr(&fprog))); r != 0 {
		return rep, fmt.tprintf("seccomp: errno %d", -r)
	}
	rep.seccomp = true
	return rep, ""
}

// ---------------------------------------------------------------------------
// The policy for one identity's assistant
// ---------------------------------------------------------------------------

// Places names the directories an identity's assistant owns. Every one is
// derived from $HOME and the handle, and none of them is shared with another
// identity: an assistant that needed a directory holding two identities'
// files could read both, and then the scope would be a convention again.
Places :: struct {
	home:   string,
	handle: string,
	drive:  string, // ~/Drive/<handle>, the synced folder
	notes:  string, // ~/Notes/<handle>
	mail:   string, // ~/Mail/<handle>, the identity's Maildir
	state:  string, // ~/.local/share/palm/assistant/<handle>: session, scratch, audit, DAV copy
	index:  string, // ~/.local/share/palm/index/<handle>: the search index, read only
}

places_for :: proc(home, handle: string, allocator := context.allocator) -> Places {
	return Places {
		home = strings.clone(home, allocator),
		handle = strings.clone(handle, allocator),
		drive = fmt.aprintf("%s/Drive/%s", home, handle, allocator = allocator),
		notes = fmt.aprintf("%s/Notes/%s", home, handle, allocator = allocator),
		mail = fmt.aprintf("%s/Mail/%s", home, handle, allocator = allocator),
		state = fmt.aprintf("%s/.local/share/palm/assistant/%s", home, handle, allocator = allocator),
		index = fmt.aprintf("%s/.local/share/palm/index/%s", home, handle, allocator = allocator),
	}
}

// SYSTEM_READ is what a dynamically linked Odin program and its children need
// to start and resolve a loopback address: the C library, the loader's
// cache, the time zone database. Nothing under it is a person's data.
SYSTEM_READ := [?]string {
	"/usr/lib",
	"/usr/lib64",
	"/lib",
	"/lib64",
	"/usr/share/zoneinfo",
	"/etc/ld.so.cache",
	"/etc/localtime",
	"/etc/hosts",
	"/etc/nsswitch.conf",
	"/etc/resolv.conf",
	"/etc/host.conf",
	"/etc/gai.conf",
}

// The program loader, which the kernel opens with exec rights to start any
// dynamically linked binary.
// A path that does not exist is skipped (and reported), so both
// architectures' loaders are listed.
SYSTEM_EXEC := [?]string {
	"/usr/lib64/ld-linux-x86-64.so.2",
	"/usr/lib/ld-linux-x86-64.so.2",
	"/lib/ld-linux-aarch64.so.1",
	"/usr/lib/ld-linux-aarch64.so.1",
}

SYSTEM_DEVICES := [?]string{"/dev/null", "/dev/urandom", "/dev/zero"}

// policy_for is the whole sandbox for one identity's assistant: its places
// read-write, the tool binaries executable, the system libraries readable,
// and the listed ports. `tools` is a directory holding only the binaries the
// assistant may run.
policy_for :: proc(pl: Places, tools: []string, ports: []u16, allocator := context.allocator) -> Policy {
	ro := make([dynamic]string, allocator)
	for s in SYSTEM_READ {append(&ro, s)}
	// The identity's own search index, read only: the daemon writes it, as
	// the person, and the assistant may only search it.
	append(&ro, pl.index)
	ex := make([dynamic]string, allocator)
	for s in SYSTEM_EXEC {append(&ex, s)}
	for t in tools {append(&ex, t)}
	rw := make([dynamic]string, allocator)
	append(&rw, pl.drive, pl.notes, pl.mail, pl.state)
	dv := make([dynamic]string, allocator)
	for s in SYSTEM_DEVICES {append(&dv, s)}
	return Policy {
		read_only = ro[:],
		execute = ex[:],
		read_write = rw[:],
		devices = dv[:],
		tcp_connect = ports,
	}
}

// ensure_places creates the read-write directories, 0700, before entering:
// once confined, a missing directory under $HOME cannot be made.
ensure_places :: proc(pl: Places) {
	for d in ([?]string{pl.drive, pl.notes, pl.mail, pl.state}) {
		os.make_directory_all(d, os.perm_number(0o700))
	}
}
