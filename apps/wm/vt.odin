// vt.odin — the virtual terminal, without logind.
//
// With logind, the session's VT is logind's business: TakeControl puts it in
// graphics mode and PauseDevice/ResumeDevice bracket every switch (seat.odin).
// Palmframe has no logind, so on bare metal wm does what logind would have
// done, the way X servers and weston-launch always did it:
//
//   - KDSETMODE KD_GRAPHICS, so the kernel console stops drawing over us and
//     does not blank or scroll the screen on its own.
//   - KDSKBMODE K_OFF, so the VT's tty sees no keys. evdev already grabs the
//     devices; this is the belt to that pair of braces, and it is what keeps
//     Ctrl+C on a shared VT from reaching anything.
//   - VT_SETMODE VT_PROCESS with SIGUSR1/SIGUSR2: the kernel asks before it
//     switches away from us (we drop DRM master, let go of the input devices,
//     then VT_RELDISP 1) and tells us when we are back (VT_RELDISP VT_ACKACQ,
//     take master, modeset, grab the devices again, repaint everything).
//   - Ctrl+Alt+F1..F12 call VT_ACTIVATE. On the other VT the kernel's own
//     keyboard handler sees Ctrl+Alt+Fn again (we let go of the grab), so the
//     way back is the console's.
//   - Text mode, the keyboard mode and VT_AUTO are restored on exit, and on a
//     crash from the signal handler, so a dead compositor never leaves a VT
//     that shows nothing and takes no keys.
//
// Which VT. XDG_VTNR (or PALMY_WM_VT) when set, which is how a login manager
// says it; otherwise stdin when it is a VT; otherwise the active VT from
// /dev/tty0. The VT ioctls need the VT to be the caller's controlling
// terminal, or CAP_SYS_TTY_CONFIG. palm-login makes the session a session
// leader (setsid), so opening the VT without O_NOCTTY makes it ours; TIOCSCTTY
// is tried when that did not happen. A user session additionally needs the
// node to be writable by the user, which login(1) has always arranged by
// chown'ing the tty. Without any of that wm runs as it did before: no VT
// switching, and a note in the log saying why.
package wm

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/linux"
import p "palmy:."

KDSETMODE :: u32(0x4B3A)
KDGETMODE :: u32(0x4B3B)
KDGKBMODE :: u32(0x4B44)
KDSKBMODE :: u32(0x4B45)
KD_TEXT :: 0
KD_GRAPHICS :: 1
K_OFF :: 0x04
VT_GETMODE :: u32(0x5601)
VT_SETMODE :: u32(0x5602)
VT_GETSTATE :: u32(0x5603)
VT_RELDISP :: u32(0x5605)
VT_ACTIVATE :: u32(0x5606)
VT_WAITACTIVE :: u32(0x5607)
VT_AUTO :: 0
VT_PROCESS :: 1
VT_ACKACQ :: 2
TIOCSCTTY :: u32(0x540E)
TTY_MAJOR :: 4

Vt_Mode :: struct {
	mode:   i8,
	waitv:  i8,
	relsig: i16,
	acqsig: i16,
	frsig:  i16,
}

Vt_Stat :: struct {
	v_active: u16,
	v_signal: u16,
	v_state:  u16,
}

Vt :: struct {
	ok:          bool, // we hold a VT in graphics/process mode
	fd:          linux.Fd,
	num:         int,
	kb_mode:     i32, // to put back
	active:      bool, // the VT is in front; false between release and acquire
	pipe:        [2]linux.Fd, // the signal handlers' wake-up
	switches:    int, // releases + acquires, for the log and the tests
	why:         string, // why there is no VT, when there is not
}

vt: Vt = {
	fd   = -1,
	pipe = {-1, -1},
}

// Set by the signal handlers, read by vt_pump.
vt_release_pending: i32
vt_acquire_pending: i32

vt_on_release :: proc "c" (sig: linux.Signal) {
	vt_release_pending = 1
	vt_wake()
}

vt_on_acquire :: proc "c" (sig: linux.Signal) {
	vt_acquire_pending = 1
	vt_wake()
}

vt_wake :: proc "contextless" () {
	if vt.pipe[1] >= 0 {
		b := [1]u8{1}
		linux.write(vt.pipe[1], b[:])
	}
}

// vt_ioctl is ioctl with the errno split out.
vt_ioctl :: proc "contextless" (fd: linux.Fd, req: u32, arg: uintptr) -> i32 {
	r := i64(linux.ioctl(fd, req, arg))
	return r < 0 ? i32(-r) : 0
}

// vt_restore_raw puts the VT back into text mode. Async-signal-safe: nothing
// but ioctls on a descriptor opened long ago.
vt_restore_raw :: proc "contextless" () {
	if !vt.ok || vt.fd < 0 {
		return
	}
	vt_ioctl(vt.fd, KDSETMODE, KD_TEXT)
	vt_ioctl(vt.fd, KDSKBMODE, uintptr(vt.kb_mode))
	m := Vt_Mode {
		mode = VT_AUTO,
	}
	vt_ioctl(vt.fd, VT_SETMODE, uintptr(&m))
}

// The crash path. Whatever killed us, the VT goes back to text first, then
// the signal is re-raised with its default action so the exit status and the
// core dump are the real ones.
vt_on_crash :: proc "c" (sig: linux.Signal) {
	vt_restore_raw()
	dfl := linux.Sig_Action {
		special = .SIG_DFL,
	}
	linux.rt_sigaction(sig, &dfl, nil)
	linux.kill(linux.getpid(), sig)
}

// vt_pick says which VT to use, or 0 with a reason.
vt_pick :: proc() -> (n: int, why: string) {
	for name in ([?]string{"PALMY_WM_VT", "XDG_VTNR"}) {
		v := os.get_env(name, context.temp_allocator)
		if v == "" {
			continue
		}
		if v == "off" || v == "0" {
			return 0, fmt.tprintf("%s=%s", name, v)
		}
		if x, ok := strconv.parse_int(v); ok && x > 0 && x < 64 {
			return x, ""
		}
	}
	st: linux.Stat
	if linux.fstat(0, &st) == .NONE && (transmute(u32)st.mode & 0o170000) == 0o020000 {
		major := (st.rdev >> 8) & 0xfff
		minor := (st.rdev & 0xff) | ((st.rdev >> 12) & 0xfff00)
		if major == TTY_MAJOR && minor >= 1 && minor < 64 {
			return int(minor), ""
		}
	}
	fd, err := linux.open("/dev/tty0", {.NOCTTY, .CLOEXEC})
	if err != .NONE {
		return 0, fmt.tprintf("no XDG_VTNR, stdin is not a VT, /dev/tty0: %v", err)
	}
	defer linux.close(fd)
	vs: Vt_Stat
	if e := vt_ioctl(fd, VT_GETSTATE, uintptr(&vs)); e != 0 {
		return 0, fmt.tprintf("VT_GETSTATE errno %d", e)
	}
	return int(vs.v_active), ""
}

// vt_open takes the VT. Returns false, with vt.why set, when there is none to
// take; wm then runs without VT handling, which is how it always ran.
vt_open :: proc() -> bool {
	n, why := vt_pick()
	if n == 0 {
		vt.why = why
		return false
	}
	path := fmt.ctprintf("/dev/tty%d", n)
	// Not O_NOCTTY: a session leader without a terminal (palm-login's
	// setsid) gets this one, which is what the VT ioctls ask for.
	fd, err := linux.open(path, {.RDWR, .CLOEXEC})
	if err != .NONE {
		vt.why = fmt.tprintf("%s: %v", path, err)
		return false
	}
	// Which mode it is in now tells us whether we may change it.
	kb: i32
	if e := vt_ioctl(fd, KDGKBMODE, uintptr(&kb)); e != 0 {
		vt.why = fmt.tprintf("%s: KDGKBMODE errno %d (not a VT?)", path, e)
		linux.close(fd)
		return false
	}
	if e := vt_ioctl(fd, KDSETMODE, KD_GRAPHICS); e == 1 {
		// EPERM: not our controlling terminal. Take it if we may.
		vt_ioctl(fd, TIOCSCTTY, 0)
		if e2 := vt_ioctl(fd, KDSETMODE, KD_GRAPHICS); e2 != 0 {
			vt.why = fmt.tprintf("%s is not this session's terminal and wm lacks CAP_SYS_TTY_CONFIG (errno %d)", path, e2)
			linux.close(fd)
			return false
		}
	} else if e != 0 {
		vt.why = fmt.tprintf("%s: KDSETMODE errno %d", path, e)
		linux.close(fd)
		return false
	}
	vt.fd = fd
	vt.num = n
	vt.kb_mode = kb
	vt.ok = true

	if linux.pipe2(&vt.pipe, {.NONBLOCK, .CLOEXEC}) != .NONE {
		vt.pipe = {-1, -1}
	}
	for pair in ([?]struct {
		sig: linux.Signal,
		fn:  linux.Sig_Handler_Fn,
	}{{.SIGUSR1, vt_on_release}, {.SIGUSR2, vt_on_acquire}}) {
		sa := linux.Sig_Action {
			handler = pair.fn,
			flags   = {.RESTART},
		}
		linux.rt_sigaction(pair.sig, &sa, nil)
	}
	for sig in ([?]linux.Signal{.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE, .SIGABRT, .SIGTRAP}) {
		sa := linux.Sig_Action {
			handler = vt_on_crash,
			flags   = {.RESETHAND, .NODEFER},
		}
		linux.rt_sigaction(sig, &sa, nil)
	}

	vt_ioctl(fd, KDSKBMODE, K_OFF)
	m := Vt_Mode {
		mode   = VT_PROCESS,
		relsig = i16(linux.Signal.SIGUSR1),
		acqsig = i16(linux.Signal.SIGUSR2),
	}
	if e := vt_ioctl(fd, VT_SETMODE, uintptr(&m)); e != 0 {
		fmt.eprintfln("wm: vt: VT_SETMODE errno %d; switching away will not pause wm", e)
	}

	// Be in front. A login manager normally starts us on the VT it shows.
	vs: Vt_Stat
	if vt_ioctl(fd, VT_GETSTATE, uintptr(&vs)) == 0 && int(vs.v_active) != n {
		vt_ioctl(fd, VT_ACTIVATE, uintptr(n))
		vt_ioctl(fd, VT_WAITACTIVE, uintptr(n))
	}
	vt.active = true
	return true
}

// vt_close gives the VT back in text mode. After drm_shutdown, so the console
// redraws over the mode it restored.
vt_close :: proc() {
	if !vt.ok {
		return
	}
	vt_restore_raw()
	vt.ok = false
	linux.close(vt.fd)
	vt.fd = -1
	for &f in vt.pipe {
		if f >= 0 {
			linux.close(f)
			f = -1
		}
	}
}

vt_poll_fd :: proc() -> linux.Fd {
	return vt.ok ? vt.pipe[0] : -1
}

// vt_inactive says the session is switched away: draw nothing, read nothing.
vt_inactive :: proc() -> bool {
	return vt.ok && !vt.active
}

// vt_switch_to asks the kernel to show VT n. Our release handler runs when
// the kernel asks us to let go.
vt_switch_to :: proc(n: int) -> bool {
	if !vt.ok || n == vt.num {
		return vt.ok
	}
	if e := vt_ioctl(vt.fd, VT_ACTIVATE, uintptr(n)); e != 0 {
		fmt.eprintfln("wm: vt: VT_ACTIVATE %d errno %d", n, e)
		return false
	}
	return true
}

// vt_switch_key is Ctrl+Alt+F1..F12, taken before any binding or client.
vt_switch_key :: proc(code: u32, mods: p.Modifiers) -> bool {
	if !vt.ok || .Ctrl not_in mods || .Alt not_in mods {
		return false
	}
	n := 0
	switch code {
	case 59 ..= 68:
		n = int(code) - 58 // KEY_F1..KEY_F10
	case 87:
		n = 11
	case 88:
		n = 12
	case:
		return false
	}
	vt_switch_to(n)
	return true
}

// vt_pump does the switch the signal handlers asked for. Returns true when
// the session just came back and everything must be repainted.
vt_pump :: proc(s: ^Server) -> (back: bool) {
	if !vt.ok {
		return false
	}
	if vt.pipe[0] >= 0 {
		buf: [64]u8
		for {
			n, err := linux.read(vt.pipe[0], buf[:])
			if err != .NONE || n <= 0 {
				break
			}
		}
	}
	if vt_release_pending != 0 {
		vt_release_pending = 0
		vt_release(s)
	}
	if vt_acquire_pending != 0 {
		vt_acquire_pending = 0
		back = vt_acquire(s)
	}
	return
}

// vt_release lets go: of every key a client holds, of the input devices, of
// DRM master. Then it tells the kernel it may switch.
vt_release :: proc(s: ^Server) {
	if !vt.active {
		vt_ioctl(vt.fd, VT_RELDISP, 1)
		return
	}
	kbd_release_clients(s)
	ev_pause_all()
	clear(&ev_queue)
	ev_grab_all(false)
	drm_pause()
	vt.active = false
	vt.switches += 1
	if e := vt_ioctl(vt.fd, VT_RELDISP, 1); e != 0 {
		fmt.eprintfln("wm: vt: VT_RELDISP errno %d", e)
	}
	fmt.printfln("wm: vt: switched away from tty%d; display and input released", vt.num)
}

// vt_acquire takes everything back and asks for a full repaint.
vt_acquire :: proc(s: ^Server) -> bool {
	vt_ioctl(vt.fd, VT_RELDISP, VT_ACKACQ)
	if vt.active {
		return false
	}
	vt_ioctl(vt.fd, KDSETMODE, KD_GRAPHICS)
	vt_ioctl(vt.fd, KDSKBMODE, K_OFF)
	drm_resume()
	ev_open_pending()
	ev_grab_all(true)
	ev_flush_all()
	ev_resume_all()
	xkb_release_all()
	vt.active = true
	vt.switches += 1
	damage_all()
	fmt.printfln("wm: vt: back on tty%d; display and input reacquired", vt.num)
	return true
}

// kbd_release_clients sends a release for every key a client holds, then
// clear modifiers, so nothing is stuck down when we come back.
kbd_release_clients :: proc(s: ^Server) {
	t := bare_mono_ms()
	for code in 0 ..= EV_KEY_MAX {
		if kbd_wire.sent[code] {
			kbd_wire.sent[code] = false
			key_send(s, u32(code), t, false)
		}
	}
	kbd_wire.swallowed = {}
	key_send_state(s, 0, 0, kbd_wire.lock, kbd_wire.grp)
}
