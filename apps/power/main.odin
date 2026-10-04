package main

// A power and session applet for Wayland, drawn by palmy's software
// rasterizer.
//
// Two things about this program are deliberate and worth stating up front.
//
// 1. There is no battery gauge. /sys/class/power_supply on this machine is
//    empty and DMI calls the chassis a mini PC, not a portable. Drawing a
//    battery here would mean inventing a number, so it says what it found and
//    shows the things that are genuinely present: uptime, sessions, the CPU's
//    frequency policy, thermal state, and whatever upower can see (which here
//    is a Bluetooth headset reporting its own charge).
//
// 2. The session actions — lock, log out, suspend, reboot, shut down — are
//    wired to a stub. `perform` writes the exact command it would have run to
//    the log and to stderr, and runs nothing. The window says so on every
//    button and again in the confirmation dialog. These applets are driven by
//    synthetic-input demo scripts, and a demo script must not be able to
//    reboot somebody's machine.

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."

HEADER_H :: 100
FOOTER_H :: 46
RIGHT_W :: 408

// Cheap readings: uptime, frequencies.
FAST_PERIOD :: 1.0
// Subprocesses: loginctl and upower. Both answer in single-digit milliseconds
// on this machine, but there is no reason to run them sixty times a second.
SLOW_PERIOD :: 5.0

Action :: enum {
	Lock,
	Logout,
	Suspend,
	Reboot,
	Shutdown,
}

Action_Info :: struct {
	label:   string,
	desc:    string,
	cmd:     string, // what a real implementation would run
	icon:    p.Icon,
	severe:  bool, // the ones that take the machine away
	key:     string,
}

ACTIONS := [Action]Action_Info {
	.Lock = {
		label = "Lock screen",
		desc = "Blank and lock this session; everything keeps running.",
		cmd = "loginctl lock-session",
		icon = IC_LOCK,
		severe = false,
		key = "L",
	},
	.Logout = {
		label = "Log out",
		desc = "End the session and return to the display manager.",
		cmd = "loginctl terminate-session self",
		icon = IC_LOG_OUT,
		severe = true,
		key = "O",
	},
	.Suspend = {
		label = "Suspend",
		desc = "Sleep to RAM. Open work stays open.",
		cmd = "systemctl suspend",
		icon = IC_MOON,
		severe = false,
		key = "S",
	},
	.Reboot = {
		label = "Restart",
		desc = "Shut everything down and start again.",
		cmd = "systemctl reboot",
		icon = IC_ROTATE_CCW,
		severe = true,
		key = "B",
	},
	.Shutdown = {
		label = "Shut down",
		desc = "Power the machine off.",
		cmd = "systemctl poweroff",
		icon = IC_POWER_OFF,
		severe = true,
		key = "P",
	},
}

Model :: struct {
	arena:       virtual.Arena, // loginctl, upower, power supplies: reset every 5 s
	fast:        virtual.Arena, // the cpufreq strings: reset every second
	al:          mem.Allocator,
	host:        Host,

	up:          f64,
	idle:        f64,
	btime:       i64,
	freq:        Cpufreq,
	sessions:    []Session,
	supplies:    []Supply,
	upower:      Upower,
	temps:       []Temp,
	temps_at:    f64,
	next_temps:  f64,

	next_fast:   f64,
	next_slow:   f64,
	loaded:      bool,
	fast_ms:     f32,
	slow_ms:     f32,

	sel:         Action,
	confirm:     bool,
	confirm_sel: int, // 0 cancel, 1 go ahead

	log_open:    bool,
	help_open:   bool,

	toast:       [224]u8,
	toast_len:   int,
	toast_until: f64,
}

g_now: f64

main :: proc() {
	app, err := start_window()
	if err != "" {
		fmt.eprintfln("power: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	m := new(Model)
	virtual.arena_init_growing(&m.arena) or_else panic("arena")
	virtual.arena_init_growing(&m.fast) or_else panic("fast arena")
	m.al = virtual.arena_allocator(&m.arena)
	m.host = host_read(context.allocator)
	refresh_slow(m)
	refresh_fast(m)

	fmt.eprintfln(
		"[power] %s · chassis %s · %d power supplies in /sys/class/power_supply",
		m.host.hostname,
		chassis_label(m.host.chassis),
		len(m.supplies),
	)
	fmt.eprintfln("[power] session actions are STUBBED: nothing here executes.")

	for ui in p.frames(app) {
		g_now = f64(p.elapsed(ui))
		p.redraw(ui)

		pump_temps(m)
		if g_now >= m.next_fast {
			refresh_fast(m)
			m.next_fast = g_now + FAST_PERIOD
		}
		if g_now >= m.next_slow {
			refresh_slow(m)
			m.next_slow = g_now + SLOW_PERIOD
		}

		keys(ui, app, m)
		build(ui, m)
	}
}

note :: proc(m: ^Model, s: string) {
	n := min(len(s), len(m.toast))
	copy(m.toast[:], s[:n])
	m.toast_len = n
	m.toast_until = g_now + 8
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

// refresh_fast is files only: /proc/uptime and sixteen cpufreq reads, about a
// millisecond and a half together.
refresh_fast :: proc(m: ^Model) {
	t0 := time.tick_now()
	m.up, m.idle, _ = uptime_read()
	m.btime, _ = btime_read()
	// Not the temp allocator: palmy recycles it every frame, and the governor
	// and driver strings have to stay valid until the next fast refresh a
	// second later. (Reading them from the temp allocator is exactly the bug
	// that first showed the EPP badge the hostname.)
	virtual.arena_free_all(&m.fast)
	m.freq = cpufreq_read(virtual.arena_allocator(&m.fast))
	m.fast_ms = f32(time.duration_milliseconds(time.tick_diff(t0, time.tick_now())))
}

// refresh_slow re-runs loginctl and upower and re-reads the power supply
// directory. The arena holds everything they allocate.
refresh_slow :: proc(m: ^Model) {
	t0 := time.tick_now()
	virtual.arena_free_all(&m.arena)
	m.al = virtual.arena_allocator(&m.arena)
	m.sessions = sessions_read(m.al)
	m.supplies = supplies_read(m.al)
	m.upower = upower_read(m.al)
	m.loaded = true
	m.slow_ms = f32(time.duration_milliseconds(time.tick_diff(t0, time.tick_now())))
}

pump_temps :: proc(m: ^Model) {
	if ts, got := temps_collect(); got {
		if m.temps != nil {
			temps_free(m.temps)
		}
		m.temps = ts
		m.temps_at = g_now
	}
	if g_now >= m.next_temps && !temps_busy() {
		temps_kick()
		m.next_temps = g_now + TEMP_PERIOD
	}
}

// ---------------------------------------------------------------------------
// The stub
//
// This is the entire implementation of every session action, on purpose.
// ---------------------------------------------------------------------------

perform :: proc(m: ^Model, a: Action) {
	info := ACTIONS[a]
	log_intent(info.cmd, info.label)
	note(
		m,
		fmt.tprintf(
			"Logged the intent to %s. `%s` was NOT run — these actions are stubbed.",
			strings.to_lower(info.label, context.temp_allocator),
			info.cmd,
		),
	)
}

Log_Entry :: struct {
	cmd:   string,
	label: string,
	when_: string,
	used:  bool,
}

LOG_N :: 32
g_log: [LOG_N]Log_Entry
g_log_at: int
g_log_count: int

log_intent :: proc(cmd, label: string) {
	h, mi, s := time.clock(time.now())
	e := &g_log[g_log_at % LOG_N]
	if e.used {
		delete(e.cmd)
		delete(e.label)
		delete(e.when_)
	}
	e^ = {
		cmd = strings.clone(cmd),
		label = strings.clone(label),
		when_ = fmt.aprintf("%02d:%02d:%02d", h, mi, s),
		used = true,
	}
	g_log_at += 1
	g_log_count += 1
	fmt.eprintfln("[power] INTENT ONLY, not executed: %s   (%s)", cmd, label)
}

log_recent :: proc(n: int, al := context.temp_allocator) -> []Log_Entry {
	count := min(n, min(g_log_count, LOG_N))
	out := make([]Log_Entry, count, al)
	for i in 0 ..< count {
		out[count - 1 - i] = g_log[(g_log_at - 1 - i + LOG_N * 4) % LOG_N]
	}
	return out
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

keys :: proc(ui: ^p.Ctx, app: ^p.App, m: ^Model) {
	if p.shortcut(ui, 'q', {.Ctrl}) {
		p.quit_app(app)
	}

	// The confirmation is modal and opens on Cancel.
	if m.confirm {
		if p.key_pressed(ui, p.KEY_ESCAPE) {
			m.confirm = false
			note(m, "Cancelled")
		}
		if p.key_pressed(ui, p.KEY_LEFT) ||
		   p.key_pressed(ui, p.KEY_RIGHT) ||
		   p.key_pressed(ui, p.KEY_TAB) ||
		   p.key_pressed(ui, p.KEY_UP) ||
		   p.key_pressed(ui, p.KEY_DOWN) {
			m.confirm_sel = 1 - m.confirm_sel
		}
		if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_SPACE) {
			go_ahead := m.confirm_sel == 1
			m.confirm = false
			if go_ahead {
				perform(m, m.sel)
			} else {
				note(m, "Cancelled")
			}
		}
		return
	}

	if m.help_open {
		if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, '?') {
			m.help_open = false
		}
		return
	}
	if m.log_open {
		if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, 'c') {
			m.log_open = false
		}
		return
	}

	count := int(max(Action)) + 1
	if p.key_pressed(ui, p.KEY_DOWN) {
		m.sel = Action((int(m.sel) + 1) % count)
	}
	if p.key_pressed(ui, p.KEY_UP) {
		m.sel = Action((int(m.sel) - 1 + count) % count)
	}
	if p.key_pressed(ui, p.KEY_HOME) {m.sel = Action(0)}
	if p.key_pressed(ui, p.KEY_END) {m.sel = Action(count - 1)}

	if p.key_pressed(ui, 'l') {arm(m, .Lock)}
	if p.key_pressed(ui, 'o') {arm(m, .Logout)}
	if p.key_pressed(ui, 's') {arm(m, .Suspend)}
	if p.key_pressed(ui, 'b') {arm(m, .Reboot)}
	if p.key_pressed(ui, 'p') {arm(m, .Shutdown)}

	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_SPACE) {
		arm(m, m.sel)
	}

	if p.key_pressed(ui, 'r') {
		refresh_slow(m)
		refresh_fast(m)
		m.next_temps = g_now
		note(m, fmt.tprintf("Re-read everything in %.1f ms", m.slow_ms + m.fast_ms))
	}
	if p.key_pressed(ui, 'c') {m.log_open = true}
	if p.key_pressed(ui, '?') {m.help_open = true}
}

// arm opens the confirmation. Every action goes through it, including the
// harmless ones, because the dialog is also where the applet says that nothing
// will actually happen.
arm :: proc(m: ^Model, a: Action) {
	m.sel = a
	m.confirm = true
	m.confirm_sel = 0
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

fmt_uptime :: proc(secs: f64) -> string {
	s := int(secs)
	d := s / 86400
	h := (s % 86400) / 3600
	mi := (s % 3600) / 60
	sec := s % 60
	if d > 0 {
		return fmt.tprintf("%dd %02dh %02dm", d, h, mi)
	}
	if h > 0 {
		return fmt.tprintf("%dh %02dm %02ds", h, mi, sec)
	}
	return fmt.tprintf("%dm %02ds", mi, sec)
}

fmt_ghz :: proc(khz: u64) -> string {
	if khz == 0 {
		return "—"
	}
	return fmt.tprintf("%.2f GHz", f64(khz) / 1_000_000)
}

boot_label :: proc(btime: i64) -> string {
	if btime <= 0 {
		return "unknown"
	}
	t := time.unix(btime, 0)
	y, mo, d := time.date(t)
	h, mi, s := time.clock(t)
	_ = s
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d UTC", y, int(mo), d, h, mi)
}
