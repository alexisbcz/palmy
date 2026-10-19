package main

// Early-boot hooks, and the programs palm-init runs and waits for.
//
// A hook is an executable in one of
//
//	/usr/lib/palm-init/early.d/<name>     shipped by packages
//	/etc/palm/early.d/<name>              the administrator's
//
// Both directories are read as one list sorted by name (byte order, so
// 10-modules before 50-foo); a name in /etc replaces the one in /usr/lib, and
// one there that is not executable (an empty file, a symlink to /dev/null)
// turns the packaged hook off. Names starting with '.' or ending in '~' are
// skipped. Each hook runs to completion before the next:
//
//	as root, in /, no arguments, stdin /dev/null, stdout and stderr on the
//	console, environment PATH HOME=/root TERM=linux PALM_INIT_STAGE=early
//	and the system language (/etc/locale.conf)
//
// When they run (main.odin): after /proc /sys /dev /run /tmp are mounted and
// `/` has been checked and remounted read-write, and before the device
// permission walk, the other /etc/fstab lines, swap, the network and every
// service. So a hook that loads kernel modules (the `modules` interface,
// distro/notes/init.md) makes their devices exist before anything looks for
// them, and the filesystems in fstab can be of a type a module provides.
//
// A hook that has not finished after HOOK_TIMEOUT_MS is killed, and a
// failing one is reported; neither stops the boot. palm.single runs the
// hooks too: a rescue shell still wants its keyboard driver.

import "core:slice"
import "core:strings"
import "core:sys/linux"

EARLY_DIRS := []string{"/usr/lib/palm-init/early.d", "/etc/palm/early.d"}
HOOK_TIMEOUT_MS :: 30_000

Hook :: struct {
	name, path: string,
}

// list_hooks merges the hook directories: later directories replace earlier
// ones by name. Non-executable entries are kept in the merge (so they can
// mask) and dropped from the result.
list_hooks :: proc(dirs: []string, allocator := context.allocator) -> []Hook {
	merged := make([dynamic]Hook, context.temp_allocator)
	for dir in dirs {
		names, ok := list_dir(dir)
		if !ok {continue}
		for name in names {
			if strings.has_prefix(name, ".") || strings.has_suffix(name, "~") {continue}
			path := strings.concatenate({dir, "/", name}, context.temp_allocator)
			replaced := false
			for &h in merged {
				if h.name == name {
					h.path = path
					replaced = true
				}
			}
			if !replaced {append(&merged, Hook{name, path})}
		}
	}
	slice.sort_by(merged[:], proc(a, b: Hook) -> bool {return a.name < b.name})
	out := make([dynamic]Hook, allocator)
	for h in merged {
		if is_executable(h.path) {
			append(&out, Hook{strings.clone(h.name, allocator), strings.clone(h.path, allocator)})
		}
	}
	return out[:]
}

run_early_hooks :: proc() {
	hooks := list_hooks(EARLY_DIRS, context.temp_allocator)
	for h in hooks {
		start := now_ms()
		status, ran := run_program({h.path}, HOOK_TIMEOUT_MS, {"PALM_INIT_STAGE=early"})
		took := now_ms() - start
		switch {
		case !ran:
			say("early hook %s could not be started", h.name)
		case status == 0:
			say("early hook %s done (%d ms)", h.name, took)
		case:
			say("early hook %s: %s", h.name, describe_status(status))
		}
	}
}

// run_program forks, runs argv as root with stdout/stderr on the console,
// and waits for it: up to timeout_ms (0: as long as it takes), after which
// it and its process group are killed. Returns the wait status.
run_program :: proc(argv: []string, timeout_ms: i64, extra_env: []string = nil) -> (status: u32, ran: bool) {
	pid, ok := start_program(argv, extra_env, true)
	if !ok {return 0, false}
	deadline := now_ms() + timeout_ms
	killed := false
	for {
		st: u32
		got, err := linux.wait4(pid, &st, {.WNOHANG}, nil)
		if err == .EINTR {continue}
		if err != .NONE {return 0, false}
		if got == pid {return st, true}
		if timeout_ms > 0 && !killed && now_ms() >= deadline {
			say("%s still running after %ds; killed", argv[0], timeout_ms / 1000)
			linux.kill(-pid, .SIGKILL)
			linux.kill(pid, .SIGKILL)
			killed = true
		}
		sleep_ms(20)
	}
}

// start_program forks and execs argv (argv[0] a path or a name in PATH).
// The child is its own process group, so a timeout can kill what it
// started too. Nobody waits for it here: reap() collects it.
start_program :: proc(argv: []string, extra_env: []string, console: bool) -> (linux.Pid, bool) {
	prog := resolve_cmd(argv[0])
	if prog == "" {return 0, false}
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	cargv[0] = strings.clone_to_cstring(prog, context.temp_allocator)
	for a, i in argv[1:] {cargv[i + 1] = strings.clone_to_cstring(a, context.temp_allocator)}
	env := make([dynamic]string, context.temp_allocator)
	append(&env, "PATH=" + DEFAULT_PATH, "HOME=/root", "TERM=linux")
	append(&env, ..system_locale_env(context.temp_allocator))
	append(&env, ..extra_env)
	cenv := make([]cstring, len(env) + 1, context.temp_allocator)
	for e, i in env {cenv[i] = strings.clone_to_cstring(e, context.temp_allocator)}

	pid, err := linux.fork()
	if err != .NONE {return 0, false}
	if pid == 0 {
		empty: linux.Sig_Set
		linux.rt_sigprocmask(.SIG_SETMASK, &empty, nil)
		linux.setpgid(0, 0)
		null, _ := linux.open("/dev/null", {.RDWR})
		linux.dup2(null, 0)
		if !console {
			linux.dup2(null, 1)
			linux.dup2(null, 2)
		}
		linux.close_range(3, max(linux.Fd), {})
		linux.chdir("/")
		linux.execve(cargv[0], raw_data(cargv), raw_data(cenv))
		linux.exit(127)
	}
	return pid, true
}

// --- modules on hotplug ---------------------------------------------------------

// A device the kernel announces after boot (a USB stick, a hot-plugged
// keyboard) carries MODALIAS in its uevent; when the kernel has loadable
// modules, palm-init asks modprobe for the driver, as udev would. The boot's
// own devices are the `modules` early hook's to load (distro/notes/init.md):
// they were announced before anyone was listening.
@(private = "file")
modprobe_path: string
@(private = "file")
modprobe_checked: bool

hotplug_modprobe :: proc(modalias: string) {
	if !modprobe_checked {
		modprobe_checked = true
		if exists("/proc/modules") {
			modprobe_path = resolve_cmd("modprobe")
		}
	}
	if modprobe_path == "" {return}
	start_program({modprobe_path, "-b", "-q", modalias}, nil, false)
}
