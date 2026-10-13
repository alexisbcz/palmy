package main

// The one place the GUI meets the machine.
//
// Everything that reads the system or changes it goes through here, and each
// procedure has exactly two branches: --demo, which returns fabricated data
// and does nothing, and the real one, which calls install_core (wrapped in
// backend_core.odin). The rest of the installer never asks which mode it is
// in for anything but a badge on the screen.
//
// Real mode is not the default anywhere it could do harm. `choose_mode` in
// main.odin only allows it as root on a Palmframe system; anywhere else the
// installer runs as --demo and says so.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sync"
import "core:thread"

Backend :: struct {
	demo:      bool,
	demo_fail: bool, // --demo-fail: the fake install fails partway
	dry_run:   bool, // --dry-run: real mode, but the core only says what it would do
}

load_languages :: proc(b: ^Backend) -> []Language {
	if b.demo {
		return demo_languages()
	}
	if l := core_languages(); len(l) > 0 {
		return l
	}
	return demo_languages()
}

load_layouts :: proc(b: ^Backend) -> []Keyboard {
	if b.demo {
		return demo_layouts()
	}
	if l := core_layouts(); len(l) > 0 {
		return l
	}
	// No xkeyboard-config: offer the layouts the wm can compile without it.
	return demo_layouts()[:1]
}

load_zones :: proc(b: ^Backend) -> []Zone {
	if b.demo {
		return demo_zones()
	}
	if z := core_zones(); len(z) > 0 {
		return z
	}
	return demo_zones()
}

load_disks :: proc(b: ^Backend) -> []Disk {
	if b.demo {
		return demo_disks()
	}
	return core_disks()
}

// check_plan is install_core.validate in real mode. The GUI validates every
// field itself as it is typed (account.odin); this is the core's last word
// before anything is written, and its problems are shown verbatim.
check_plan :: proc(b: ^Backend, p: Plan) -> (ok: bool, problems: []string) {
	if b.demo {
		return true, nil
	}
	return core_validate(p)
}

// ---------------------------------------------------------------------------
// The live keyboard layout
// ---------------------------------------------------------------------------

// apply_keyboard makes the compositor switch to `k` now, so the test field on
// the keyboard page types in the layout being looked at. INSTALLER.md: the wm
// re-reads /etc/palm/keyboard on SIGHUP.
//
// Two guards keep this from doing anything on a development machine. It is a
// no-op in --demo, and even in real mode the signal only goes to a process
// whose name is `wm` — never blindly to the parent, which on a desktop would
// be a shell or a terminal that SIGHUP closes.
apply_keyboard :: proc(b: ^Backend, k: Keyboard) -> (said: string) {
	if b.demo {
		return fmt.aprintf("demo: would write /etc/palm/keyboard (layout = %s, variant = %s) and SIGHUP the wm", k.layout, k.variant)
	}
	body := fmt.tprintf("layout = %s\nvariant = %s\noptions =\n", k.layout, k.variant)
	if err := os.write_entire_file("/etc/palm/keyboard", transmute([]u8)body); err != nil {
		return fmt.aprintf("could not write /etc/palm/keyboard: %v", err)
	}
	pid := find_wm()
	if pid <= 0 {
		return strings.clone("wrote /etc/palm/keyboard; no wm process to signal")
	}
	if linux.kill(linux.Pid(pid), .SIGHUP) != .NONE {
		return fmt.aprintf("wrote /etc/palm/keyboard; could not signal wm (pid %d)", pid)
	}
	return fmt.aprintf("keyboard %s %s; wm (pid %d) told to reload", k.layout, k.variant, pid)
}

// find_wm returns the compositor's pid: the parent when the parent is `wm`
// (it started us with --exec), otherwise the first process named `wm`.
find_wm :: proc() -> int {
	ppid := int(linux.getppid())
	if proc_comm(ppid) == "wm" {
		return ppid
	}
	f, err := os.open("/proc")
	if err != nil {
		return -1
	}
	defer os.close(f)
	infos, _ := os.read_dir(f, -1, context.temp_allocator)
	for fi in infos {
		pid := 0
		for c in fi.name {
			if c < '0' || c > '9' {
				pid = -1
				break
			}
			pid = pid * 10 + int(c - '0')
		}
		if pid > 0 && proc_comm(pid) == "wm" {
			return pid
		}
	}
	return -1
}

proc_comm :: proc(pid: int) -> string {
	data, err := os.read_entire_file(fmt.tprintf("/proc/%d/comm", pid), context.temp_allocator)
	if err != nil {
		return ""
	}
	return strings.trim_space(string(data))
}

// restart_machine is the Done page's button: busybox reboot, which signals
// palm-init (CONTRACT.md). In --demo it only says what it would do.
restart_machine :: proc(b: ^Backend) -> string {
	if b.demo {
		return strings.clone("demo: would run /sbin/reboot (nothing executed)")
	}
	if !run_detached({"/sbin/reboot"}) {
		return strings.clone("could not run /sbin/reboot")
	}
	return ""
}

run_detached :: proc(argv: []string) -> bool {
	desc := os.Process_Desc {
		command = argv,
	}
	_, err := os.process_start(desc)
	return err == nil
}

// ---------------------------------------------------------------------------
// The install, on a worker thread
// ---------------------------------------------------------------------------

// Worker is shared between the GUI thread, which reads it every frame, and
// the install thread, which writes it from `report`. Everything in it is
// behind `mu`; the strings it holds are heap copies owned by the worker, so
// the GUI may draw them after unlocking (they are never freed while the
// installer runs).
Worker :: struct {
	mu:       sync.Mutex,
	backend:  Backend,
	plan:     Plan,
	progress: Progress,
	log:      [dynamic]string,
	finished:  bool,
	ok:        bool,
	err:       string,
	core_logs: bool, // log lines arrive through worker_log, not from reports
	th:        ^thread.Thread,
}

worker_start :: proc(b: Backend, p: Plan) -> ^Worker {
	w := new(Worker)
	w.backend = b
	w.plan = p
	w.progress = Progress{step = .Partition}
	w.th = thread.create(worker_run)
	w.th.data = w
	thread.start(w.th)
	return w
}

@(private = "file")
worker_run :: proc(t: ^thread.Thread) {
	w := (^Worker)(t.data)
	ok: bool
	err: string
	if w.backend.demo {
		ok, err = demo_install(w.plan, worker_report, w, w.backend.demo_fail)
	} else {
		// The core writes its own log lines through worker_log, so its
		// progress messages need not be logged a second time.
		w.core_logs = true
		ok, err = core_install(w.plan, w)
	}
	sync.mutex_lock(&w.mu)
	w.finished = true
	w.ok = ok
	w.err = strings.clone(err)
	if !ok {
		append(&w.log, fmt.aprintf("error: %s", err))
	}
	sync.mutex_unlock(&w.mu)
}

// worker_report is the core's `report` callback, called on the install thread.
worker_report :: proc(pr: Progress, user: rawptr) {
	w := (^Worker)(user)
	sync.mutex_lock(&w.mu)
	defer sync.mutex_unlock(&w.mu)
	msg := strings.clone(pr.message)
	w.progress = Progress{step = pr.step, fraction = pr.fraction, message = msg}
	if !w.core_logs && msg != "" && (len(w.log) == 0 || w.log[len(w.log) - 1] != msg) {
		append(&w.log, msg)
	}
}

// worker_log is the core's Options.on_log, called on the install thread for
// every line it writes to /var/log/palm-install.log.
worker_log :: proc(w: ^Worker, line: string) {
	sync.mutex_lock(&w.mu)
	defer sync.mutex_unlock(&w.mu)
	append(&w.log, strings.clone(line))
}

// Snapshot is what one frame draws: a copy taken under the lock.
Snapshot :: struct {
	progress: Progress,
	log:      []string, // the newest lines, oldest first
	n_log:    int,
	finished: bool,
	ok:       bool,
	err:      string,
}

worker_snapshot :: proc(w: ^Worker, max_lines: int) -> Snapshot {
	sync.mutex_lock(&w.mu)
	defer sync.mutex_unlock(&w.mu)
	n := len(w.log)
	from := max(0, n - max_lines)
	lines := make([]string, n - from, context.temp_allocator)
	copy(lines, w.log[from:])
	return Snapshot {
		progress = w.progress,
		log = lines,
		n_log = n,
		finished = w.finished,
		ok = w.ok,
		err = w.err,
	}
}

// STEP_WEIGHT is how much of the bar each step fills in the demo, which has
// to make up its own whole-install fraction the way the core does with its
// STEP_SPAN. Packages dominate: they are the only step whose length grows
// with what is installed.
STEP_WEIGHT := [Install_Step]f32 {
	.Partition  = 3,
	.Format     = 6,
	.Mount      = 1,
	.Packages   = 60,
	.Configure  = 10,
	.Bootloader = 15,
	.Unmount    = 5,
	.Done       = 0,
}

// overall_fraction folds (step, fraction within it) into one 0..1 value.
overall_fraction :: proc(step: Install_Step, within: f32) -> f32 {
	total, before: f32
	for s in Install_Step {
		total += STEP_WEIGHT[s]
		if s < step {
			before += STEP_WEIGHT[s]
		}
	}
	if step == .Done {
		return 1
	}
	return clamp((before + STEP_WEIGHT[step] * clamp(within, 0, 1)) / total, 0, 1)
}
