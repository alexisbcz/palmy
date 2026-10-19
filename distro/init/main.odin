package main

// palm-init — Palmy's PID 1.
//
// The kernel runs it as /sbin/init. It brings the machine up, in this order:
//
//	/proc /sys /dev /run /tmp                          early.odin
//	`/` checked (fsck) and remounted as fstab says     fstab.odin
//	`/` grown to fill its disk, once, if asked         growroot.odin
//	the early hooks: kernel modules and the like       hooks.odin
//	GPU, input, sound and tty device permissions       devices.odin
//	the rest of /etc/fstab, swap; zram swap            fstab.odin, zram.odin
//	/var, /etc/machine-id, the hostname, lo            early.odin
//	the services in /etc/palm/services                 service.odin
//
// then keeps the services alive, reaps every orphan, and brings the machine
// down when asked: services stopped, swap off, filesystems unmounted, `/`
// read-only.
//
// "Asked" follows busybox's convention, so busybox's own `reboot`, `poweroff`
// and `halt` — which just signal PID 1 — work without a palm-init-specific
// tool:
//
//	SIGTERM  reboot        SIGUSR2  poweroff
//	SIGINT   reboot        SIGUSR1  halt
//	         (ctrl-alt-del)
//	SIGHUP   re-read /etc/palm/services: start what is new, restart what
//	         changed, stop what was removed (service.odin, "reload")
//
// The main loop is one ppoll over two descriptors: a signalfd carrying every
// signal init cares about (they are blocked, so they only ever arrive there,
// never as an asynchronous handler that could interrupt an allocation), and
// the netlink socket carrying hotplug uevents. Its timeout is the next
// service that is due — a restart after backoff, or a dependency's deadline.
//
//	palm-init              as PID 1 (anything else refuses to run)
//	palm-init --selftest   the parser tests, as any user, on any machine
//
// Kernel command line: palm.single (a root shell instead of services) and
// palm.autologin=<user> (exported to services as PALM_AUTOLOGIN).

import "core:fmt"
import "core:os"
import "core:sys/linux"

SIGNALS := []linux.Signal{.SIGCHLD, .SIGTERM, .SIGINT, .SIGUSR1, .SIGUSR2, .SIGHUP, .SIGPWR}

// single is palm.single: no services, and SIGHUP does not load any.
single: bool

Shutdown :: enum u8 {
	None,
	Reboot,
	Poweroff,
	Halt,
}

main :: proc() {
	for a in os.args[1:] {
		if a == "--selftest" {
			os.exit(selftest())
		}
		if a == "--help" || a == "-h" {
			fmt.println("usage: palm-init            (as PID 1)")
			fmt.println("       palm-init --selftest (parser tests)")
			fmt.println("To stop the machine use busybox reboot, poweroff or halt.")
			os.exit(0)
		}
	}
	if linux.getpid() != 1 {
		fmt.eprintln("palm-init: not PID 1; use busybox reboot/poweroff/halt to talk to init, or --selftest")
		os.exit(1)
	}
	boot()
}

boot :: proc() {
	// Signals first: from here on a SIGTERM must mean "reboot", queued until
	// the loop reads it, never the default action of killing PID 1 (which
	// the kernel would refuse anyway, but a queued request is better than a
	// lost one).
	mask: linux.Sig_Set
	for sig in SIGNALS {sigaddset(&mask, sig)}
	linux.rt_sigprocmask(.SIG_BLOCK, &mask, nil)
	sfd := signalfd(&mask)

	// ctrl-alt-del sends SIGINT to init instead of an immediate reboot.
	linux.reboot(.RB_MAGIC_1, .RB_MAGIC_2, .RB_DISABLE_CAD, nil)

	linux.umask(transmute(linux.Mode)u32(0o022))
	linux.chdir("/")

	say("Palmy is starting")
	mount_early()
	reopen_console()

	cmd := Cmdline{}
	if text, ok := read_file("/proc/cmdline", context.temp_allocator); ok {
		cmd = parse_cmdline(text)
	}
	single = cmd.single

	// `/`: checked while the kernel still has it read-only, then remounted
	// as fstab says (fstab.odin), then grown if the image asks (growroot).
	fstab := load_fstab()
	switch check_root(fstab) {
	case .Reboot:
		linux.sync()
		say("rebooting after the check of /")
		linux.reboot(.RB_MAGIC_1, .RB_MAGIC_2, .RB_AUTOBOOT, nil)
	case .Broken:
		say("/ has errors; it stays read-only")
	case .Fine:
		remount_root(fstab)
		grow_root()
	}

	passwd_text, _ := read_file("/etc/passwd")
	group_text, _ := read_file("/etc/group")
	sup.users = parse_passwd(passwd_text)
	sup.groups = parse_group(group_text)
	sup.autologin = cmd.autologin

	// The hotplug socket opens before the early hooks, so the devices of
	// modules they load are seen; the coldplug walk comes after them.
	devices_init(sup.groups)
	hotplug_open()
	run_early_hooks()
	coldplug()

	mount_fstab(fstab)
	zram_setup()
	prepare_var()
	machine_id()
	set_hostname()

	if link_up("lo") {
		say("lo up")
	} else {
		say("cannot bring lo up")
	}

	if cmd.single {
		say("palm.single: a root shell on %s instead of services", console_tty())
		add_single_shell()
	} else {
		add_builtin_network()
		n := load_services()
		say("%d services in %s", n, SERVICE_DIR)
		if cmd.autologin != "" {
			say("palm.autologin=%s passed to services as PALM_AUTOLOGIN", cmd.autologin)
		}
	}
	free_all(context.temp_allocator)

	request := run(sfd)
	shutdown(request)
}

// run is the main loop; it returns when a shutdown has been asked for.
run :: proc(sfd: linux.Fd) -> Shutdown {
	for {
		timeout := supervise()
		free_all(context.temp_allocator)

		fds := [2]linux.Poll_Fd{{fd = sfd, events = {.IN}}, {fd = devices.sock, events = {.IN}}}
		nfds := 2 if devices.sock >= 0 else 1
		ts: linux.Time_Spec
		tsp: ^linux.Time_Spec = nil
		if timeout >= 0 {
			ts = {time_sec = uint(timeout / 1000), time_nsec = uint((timeout % 1000) * 1_000_000)}
			tsp = &ts
		}
		_, perr := linux.ppoll(fds[:nfds], tsp, nil)
		if perr != .NONE && perr != .EINTR {
			// Should not happen; do not spin if it does.
			sleep_ms(100)
		}

		if nfds == 2 && .IN in fds[1].revents {
			hotplug_drain()
		}
		if .IN in fds[0].revents {
			for sig in read_signals(sfd) {
				#partial switch sig {
				case .SIGCHLD:
					reap()
				case .SIGTERM, .SIGINT:
					return .Reboot
				case .SIGUSR2, .SIGPWR:
					return .Poweroff
				case .SIGUSR1:
					return .Halt
				case .SIGHUP:
					if single {
						say("SIGHUP: palm.single runs no services; nothing to reload")
					} else {
						reload_services()
					}
				case:
				}
			}
		}
		// A SIGCHLD can be coalesced with another signal; reaping on every
		// wakeup is cheap and makes sure no zombie waits for the next one.
		reap()
	}
}

shutdown :: proc(request: Shutdown) {
	what := [Shutdown]string {
		.None     = "",
		.Reboot   = "rebooting",
		.Poweroff = "powering off",
		.Halt     = "halting",
	}
	say("%s", what[request])
	stop_all()
	linux.sync()
	unmount_all()
	linux.sync()
	op: linux.Reboot_Operation
	switch request {
	case .Reboot, .None:
		op = .RB_AUTOBOOT
	case .Poweroff:
		op = .RB_POWER_OFF
	case .Halt:
		op = .RB_HALT_SYSTEM
	}
	linux.reboot(.RB_MAGIC_1, .RB_MAGIC_2, op, nil)
	// reboot(2) does not return on success. If it did, PID 1 must still not
	// exit (the kernel would panic): wait forever.
	say("reboot(2) failed; the machine is stopped")
	for {linux.pause()}
}

// Signal plumbing. core:sys/linux has no signalfd or sigaddset yet; these are
// the system call and the kernel's bit layout (signal n is bit n-1).

sigaddset :: proc(set: ^linux.Sig_Set, sig: linux.Signal) {
	n := uint(sig) - 1
	bits := size_of(set[0]) * 8
	set[n / uint(bits)] |= 1 << (n % uint(bits))
}

signalfd :: proc(mask: ^linux.Sig_Set) -> linux.Fd {
	SFD_CLOEXEC :: 0o2000000
	SFD_NONBLOCK :: 0o4000
	// The kernel's sigset is 8 bytes on x86-64, whatever libc calls sigset_t.
	ret := linux.syscall(linux.SYS_signalfd4, -1, mask, 8, SFD_CLOEXEC | SFD_NONBLOCK)
	if ret < 0 {
		say("signalfd failed (errno %d)", -ret)
		return -1
	}
	return linux.Fd(ret)
}

// read_signals drains the signalfd. Each record is a 128-byte
// signalfd_siginfo whose first field is the u32 signal number.
read_signals :: proc(sfd: linux.Fd) -> []linux.Signal {
	out := make([dynamic]linux.Signal, context.temp_allocator)
	buf: [128 * 16]u8
	for {
		n, err := linux.read(sfd, buf[:])
		if err == .EINTR {continue}
		if err != .NONE || n <= 0 {break}
		for off := 0; off + 128 <= n; off += 128 {
			signo := (^u32)(&buf[off])^
			append(&out, linux.Signal(signo))
		}
	}
	return out[:]
}
