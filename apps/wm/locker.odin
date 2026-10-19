// locker.odin — the screen lock, drawn by the compositor itself.
//
// lock.odin is the protocol a client locker (swaylock) uses; this is the
// lock Palmy ships, and it needs no client at all:
//
//   - The compositor owns every key and every click while it is up: no
//     client has keyboard focus (set_kbd_focus refuses anything but a lock
//     surface while locked), so no client can read what is typed, and none
//     is drawn — `draw` paints the lock and returns before the desktop, the
//     windows, the bar, the popups, the notifications and the toasts. What
//     was on screen is not under a curtain; it is not drawn.
//   - The password is checked by palm-login over the session socket
//     (login.odin). The wm runs as the user and never sees /etc/shadow; it
//     never compares anything itself. palm-login rate limits (the faillock
//     tally doas uses) and answers a wrong password late.
//   - It survives anything a client does: crashing, mapping new windows,
//     asking for focus, inhibiting idle (which only defers the idle lock).
//     It survives a VT switch: the lock is the compositor's state, so the
//     VT comes back to it. It does not survive the compositor itself — and a
//     wm that dies ends the session, which palm-login tears down; nothing is
//     ever left unlocked.
//   - If a client locker took the lock (ext_session_lock_v1) and died, the
//     session stays locked (lock.odin) and this prompt is what is shown, so
//     the abandoned lock can still be opened with the password.
//
// Locks: Super+L (`bind = $mod, L, lock`), Lock in the start menu's power
// menu, `lock_after` without input (wm.conf; a window that inhibits idle
// defers it), and before a suspend.
//
// The look is the greeter's: the big clock and the date, a card with the
// person, a password field of bullets; the identity's colour rings the
// monogram when the session has one. Keyboard only works: type, Enter,
// Esc clears; Caps Lock is announced; errors say what happened in words.
package wm

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import ai "kit:appindex"
import p "palmy:."

LOCK_PW_MAX :: 512

Locker :: struct {
	pw:          [dynamic]u8, // never drawn, zeroed whenever it is dropped
	err:         string, // what the last attempt came back with
	busy:        bool, // a check is with palm-login
	locked_at:   f64,
	locked_wall: time.Time, // for "Locked at 14:05"
	why:         string, // "key", "menu", "idle", "suspend" (static strings)
	fails:       int,
	last_input:  f64, // for lock_after
	submit_r:    p.Rect, // the arrow button, for the pointer
	// Tests: the Caps Lock state as if the keyboard had it.
	caps_test:   bool,
}

locker: Locker

// locker_internal: the session is locked and no client lock surface is on
// screen, so the compositor's own prompt is what the user talks to.
locker_internal :: proc() -> bool {
	return lock_active() && lock_kbd_surface() == nil
}

// locker_lock locks the session now. False (with a toast) when it cannot be
// unlocked again: no palm-login to check the password.
locker_lock :: proc(s: ^Server, why: string) -> bool {
	if session.kiosk {
		return false
	}
	if !login_available() {
		toast(s, "Lock needs palm-login, which is not running this session")
		return false
	}
	if lock_active() {
		return true
	}
	start_close(s)
	menu_close(s)
	power_cancel(s)
	lock_state = .Locked
	lock_abandoned = false
	locker_forget()
	locker.locked_at = wall_now()
	locker.locked_wall, _ = clock_now()
	locker.why = why
	lock_blank(s)
	damage_all()
	fmt.printfln("wm: session locked (%s)", why)
	log_line("session locked by the compositor (%s)", why)
	return true
}

// locker_forget drops the password, the error and any pending check.
locker_forget :: proc() {
	login_zero(locker.pw[:])
	clear(&locker.pw)
	delete(locker.err)
	locker.err = ""
	locker.busy = false
	locker.fails = 0
}

// locker_unlock is what a right password does.
locker_unlock :: proc(s: ^Server) {
	// A client locker still holding the session (it never drew, or drew
	// and stopped answering) is told the lock is over.
	if lock_session != nil && !lock_session.finished {
		lock_session.finished = true
		event(lock_session.client, lock_session.id, 1) // finished
		client_flush(lock_session.client)
	}
	fmt.printfln("wm: session unlocked after %.0fs", wall_now() - locker.locked_at)
	log_line("session unlocked")
	lock_clear(s) // calls locker_forget
	locker.last_input = wall_now()
	damage_all()
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

// locker_key handles one key while the prompt is up. Every key is the
// lock's: nothing returns false.
locker_key :: proc(s: ^Server, k: p.Key_Event) {
	s.dirty = true
	if locker.busy {
		return // the answer is on its way; typing now would be lost anyway
	}
	ctrl := .Ctrl in k.mods
	switch k.sym {
	case p.KEY_ESCAPE:
		login_zero(locker.pw[:])
		clear(&locker.pw)
		delete(locker.err)
		locker.err = ""
		return
	case p.KEY_RETURN, KEY_KP_ENTER:
		locker_submit(s)
		return
	case p.KEY_BACKSPACE:
		if ctrl {
			login_zero(locker.pw[:])
			clear(&locker.pw)
		} else if len(locker.pw) > 0 {
			_, w := utf8.decode_last_rune(locker.pw[:])
			w = max(w, 1)
			login_zero(locker.pw[len(locker.pw) - w:])
			resize(&locker.pw, len(locker.pw) - w)
		}
		return
	}
	if ctrl || .Alt in k.mods || .Super in k.mods {
		if ctrl && (k.sym == 'u' || k.sym == 'U') {
			login_zero(locker.pw[:])
			clear(&locker.pw)
		}
		return
	}
	r, ok := key_rune(k.sym)
	if !ok || r < 0x20 {
		return
	}
	b, n := utf8.encode_rune(r)
	if len(locker.pw) + n > LOCK_PW_MAX {
		return
	}
	if len(locker.pw) == 0 && locker.err != "" {
		// A new attempt: the old error has been read.
		delete(locker.err)
		locker.err = ""
	}
	append(&locker.pw, ..b[:n])
}

locker_submit :: proc(s: ^Server) {
	if locker.busy || len(locker.pw) == 0 {
		return
	}
	sb := login_unlock_payload(string(locker.pw[:]))
	ok, why := login_send(.Unlock, strings.to_string(sb))
	login_zero(sb.buf[:])
	login_zero(locker.pw[:])
	clear(&locker.pw)
	delete(locker.err)
	locker.err = ""
	if !ok {
		locker.err = strings.clone(fmt.tprintf("The password cannot be checked: %s.", why))
		return
	}
	locker.busy = true
}

locker_on_reply :: proc(s: ^Server, r: Login_Reply) {
	locker.busy = false
	if r.ok {
		if lock_active() {
			locker_unlock(s)
		}
		return
	}
	locker.fails += 1
	delete(locker.err)
	switch {
	case r.description != "" && r.error_type == "auth_error":
		locker.err = strings.clone(r.description)
	case r.description != "":
		locker.err = strings.clone(fmt.tprintf("The password cannot be checked: %s.", r.description))
	case:
		locker.err = strings.clone("The password was not accepted.")
	}
	fmt.printfln("wm: unlock refused (%d): %s", locker.fails, locker.err)
}

// locker_pointer: a click on the arrow submits; the rest of the screen is
// inert.
locker_pointer :: proc(s: ^Server, app: ^p.App, mp: [2]int) {
	in_ := &app.win.input
	if in_.pressed[.Left] && p.rect_contains(locker.submit_r, f32(mp.x), f32(mp.y)) {
		locker_submit(s)
		s.dirty = true
	}
}

// locker_caps: is Caps Lock on?
locker_caps :: proc(app: ^p.App) -> bool {
	if locker.caps_test {
		return true
	}
	if app != nil && .Caps in app.win.input.mods {
		return true
	}
	return session.bare && kbd_wire.lock & 2 != 0
}

// ---------------------------------------------------------------------------
// Idle
// ---------------------------------------------------------------------------

// locker_tick notes input and locks after `lock_after` seconds without any.
// Called once a frame, after the input has been read.
locker_tick :: proc(s: ^Server, app: ^p.App) {
	in_ := &app.win.input
	now := wall_now()
	if locker.last_input == 0 {
		locker.last_input = now
	}
	if len(in_.keys) > 0 || in_.mouse_delta != {0, 0} || in_.scroll != {0, 0} ||
	   in_.pressed[.Left] || in_.pressed[.Right] || in_.pressed[.Middle] {
		locker.last_input = now
	}
	after := f64(s.cfg.lock_after)
	if after <= 0 || lock_active() || session.kiosk || !login_available() {
		return
	}
	if lock_idle_inhibited() || power_active() {
		// A video playing, or the machine on its way down: not idle.
		locker.last_input = now
		return
	}
	if now - locker.last_input >= after {
		locker_lock(s, "idle")
		return
	}
	wake_at(locker.last_input + after)
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

Locker_Look :: struct {
	bg_top, bg_bot: u32,
	text, dim, faint: u32,
	card, card_line: u32,
	field, field_line: u32,
	ring: u32, // focus ring of the field
	error, warn: u32,
}

locker_look :: proc() -> Locker_Look {
	if pal.dark {
		// The greeter's wash, #121217 to #07070a, and shadcn's dark card.
		return {
			bg_top = 0x121217, bg_bot = 0x07070a,
			text = 0xfafafa, dim = 0xa1a1aa, faint = 0x71717a,
			card = 0x0f0f12, card_line = 0x27272a,
			field = 0x09090b, field_line = 0x3f3f46,
			ring = pal.accent,
			error = 0xf87171, warn = 0xfbbf24,
		}
	}
	return {
		bg_top = 0xf4f4f5, bg_bot = 0xe4e4e7,
		text = 0x09090b, dim = 0x52525b, faint = 0x71717a,
		card = 0xffffff, card_line = 0xe4e4e7,
		field = 0xffffff, field_line = 0xd4d4d8,
		ring = pal.accent,
		error = 0xdc2626, warn = 0xb45309,
	}
}

// locker_person is who is locked out: the passwd GECOS name, else $USER.
locker_person :: proc() -> (name: string, login: string) {
	login = os.get_env("USER", context.temp_allocator)
	if login == "" {
		login = os.get_env("LOGNAME", context.temp_allocator)
	}
	name = login
	if pw, err := os.read_entire_file("/etc/passwd", context.temp_allocator); err == nil && login != "" {
		rest := string(pw)
		for line in strings.split_lines_iterator(&rest) {
			f := strings.split(line, ":", context.temp_allocator)
			if len(f) >= 5 && f[0] == login {
				g := f[4]
				if c := strings.index_byte(g, ','); c >= 0 {
					g = g[:c]
				}
				if strings.trim_space(g) != "" {
					name = strings.trim_space(g)
				}
			}
		}
	}
	if name == "" {
		name = "This computer"
	}
	return
}

LONG_WEEKDAYS := [7]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
LONG_MONTHS := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}

// locker_draw paints the lock on every output. It never reads a window.
locker_draw :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas) {
	lk := locker_look()
	W, H := f32(cv.w), f32(cv.h)
	p.fill_rect_paint(cv, {0, 0, W, H}, p.gradient(p.hex(lk.bg_top), p.hex(lk.bg_bot), true))
	drew := false
	for o in s.outputs {
		if !o.enabled {
			continue
		}
		wm_reset_clip(cv)
		p.push_clip(cv, {f32(o.x), f32(o.y), f32(o.w), f32(o.h)})
		locker_draw_output(s, app, cv, lk, {f32(o.x), f32(o.y), f32(o.w), f32(o.h)})
		p.pop_clip(cv)
		drew = true
	}
	if !drew {
		locker_draw_output(s, app, cv, lk, {0, 0, W, H})
	}
	wm_reset_clip(cv)
}

locker_draw_output :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, lk: Locker_Look, area: p.Rect) {
	f := &app.fonts
	cx := area.x + area.w / 2
	// The clock, as the greeter has it: big, then the date under it.
	now, _ := clock_now()
	h, m, _ := time.clock_from_time(now)
	y, mon, d := time.date(now)
	wd := int(time.weekday(now))
	clock := fmt.tprintf("%02d:%02d", h, m)
	top := area.y + max(area.h * 0.12, 48)
	csz := f32(96)
	if area.h < 640 {
		csz = 64
	}
	cw := p.text_width(f, clock, csz, .Sans, .Bold)
	p.draw_text(cv, f, clock, cx - cw / 2, top + csz * 0.8, csz, p.hex(lk.text), .Sans, .Bold)
	date := fmt.tprintf("%s, %d %s %d", LONG_WEEKDAYS[wd % 7], d, LONG_MONTHS[(int(mon) - 1) % 12], y)
	dw := p.text_width(f, date, 18, .Sans)
	p.draw_text(cv, f, date, cx - dw / 2, top + csz * 0.8 + 36, 18, p.hex(lk.dim), .Sans)

	// The card.
	CW :: f32(440)
	CH :: f32(214)
	card := p.Rect{cx - CW / 2, max(top + csz + 70, area.y + area.h * 0.45 - CH / 2), CW, CH}
	p.drop_shadow(cv, card, {14, 14, 14, 14}, 40, 0, {0, 16}, p.rgba(0, 0, 0, pal.dark ? 150 : 40))
	p.fill_round_rect(cv, card, {14, 14, 14, 14}, p.hex(lk.card))
	p.stroke_round_rect(cv, card, {14, 14, 14, 14}, 1, p.hex(lk.card_line))

	// The person, and the identity when there is one.
	name, login := locker_person()
	id := shell_identity()
	ax, ay := card.x + 24 + 26, card.y + 24 + 26
	ring := id.ok && id.color != 0 ? id.color : 0
	p.fill_circle(cv, ax, ay, 26, p.hex(ring != 0 ? mix(ring, lk.card, 0.78) : (pal.dark ? 0x27272a : 0xf4f4f5)))
	if ring != 0 {
		p.stroke_round_rect(cv, {ax - 26, ay - 26, 52, 52}, {26, 26, 26, 26}, 2, p.hex(ring))
	}
	mg := monogram(name)
	mw := p.text_width(f, mg, 20, .Sans, .Semibold)
	p.draw_text(cv, f, mg, ax - mw / 2, ay + 7, 20, p.hex(ring != 0 ? ring : lk.text), .Sans, .Semibold)
	tx := ax + 26 + 16
	p.draw_text(cv, f, ellipsize_end(f, name, 17, .Semibold, CW - 140), tx, ay - 3, 17, p.hex(lk.text), .Sans, .Semibold)
	sub := login
	if id.ok {
		sub = fmt.tprintf("%s · %s", login, id.name)
	}
	p.draw_text(cv, f, ellipsize_end(f, sub, 12.5, .Regular, CW - 140), tx, ay + 16, 12.5, p.hex(lk.dim), .Sans)
	// A small padlock at the card's corner says what this is.
	p.draw_icon(cv, wm_icons(), ai.ICON_LOCK, card.x + CW - 24 - 18, ay - 9, 18, p.hex(lk.faint))

	// The password field and its button.
	p.draw_text(cv, f, "Password", card.x + 24, card.y + 104, 12, p.hex(lk.dim), .Sans, .Medium)
	field := p.Rect{card.x + 24, card.y + 114, CW - 48 - 52, 44}
	invalid := locker.err != "" && len(locker.pw) == 0
	p.fill_round_rect(cv, field, {9, 9, 9, 9}, p.hex(lk.field))
	if invalid {
		p.stroke_round_rect(cv, p.rect_inset(field, -2), {11, 11, 11, 11}, 3, p.fade(p.hex(lk.error), 0.25))
		p.stroke_round_rect(cv, field, {9, 9, 9, 9}, 1, p.hex(lk.error))
	} else {
		p.stroke_round_rect(cv, p.rect_inset(field, -2), {11, 11, 11, 11}, 3, p.fade(p.hex(lk.ring), 0.35))
		p.stroke_round_rect(cv, field, {9, 9, 9, 9}, 1, p.hex(lk.ring))
	}
	ty := field.y + field.h / 2
	if locker.busy {
		p.draw_text(cv, f, "Checking…", field.x + 14, ty + 5, 14, p.hex(lk.faint), .Sans)
	} else if len(locker.pw) == 0 {
		// The caret, steady (a blinking one would keep the machine drawing
		// all night), then the placeholder.
		p.fill_rect(cv, {field.x + 14, ty - 10, 2, 20}, p.hex(lk.ring))
		p.draw_text(cv, f, "Enter your password", field.x + 22, ty + 5, 14, p.hex(lk.faint), .Sans)
	} else {
		n := utf8.rune_count(string(locker.pw[:]))
		dots := min(n, int((field.w - 40) / 13))
		for i in 0 ..< dots {
			p.fill_circle(cv, field.x + 18 + f32(i) * 13, ty, 4, p.hex(lk.text))
		}
		p.fill_rect(cv, {field.x + 18 + f32(dots) * 13 - 3, ty - 10, 2, 20}, p.hex(lk.ring))
	}
	if locker_caps(app) {
		// Inside the field, where the eyes are while typing.
		label := "Caps Lock"
		lw := p.text_width(f, label, 11, .Sans, .Semibold) + 16
		pill := p.Rect{field.x + field.w - lw - 8, ty - 11, lw, 22}
		p.fill_round_rect(cv, pill, {6, 6, 6, 6}, p.fade(p.hex(lk.warn), 0.18))
		p.draw_text(cv, f, label, pill.x + 8, ty + 4, 11, p.hex(lk.warn), .Sans, .Semibold)
	}
	btn := p.Rect{field.x + field.w + 8, field.y, 44, 44}
	locker.submit_r = btn
	ready := len(locker.pw) > 0 && !locker.busy
	p.fill_round_rect(cv, btn, {9, 9, 9, 9}, p.hex(ready ? pal.accent : (pal.dark ? 0x27272a : 0xe4e4e7)))
	p.draw_icon(cv, wm_icons(), ai.ICON_CHEVRON_RIGHT, btn.x + 12, btn.y + 12, 20, p.hex(ready ? pal.on_accent : lk.faint))

	// One line under the field: what went wrong, else Caps Lock, else how.
	ly := field.y + field.h + 26
	switch {
	case locker.err != "":
		p.fill_circle(cv, card.x + 30, ly - 4.5, 3.5, p.hex(lk.error))
		p.draw_text(cv, f, ellipsize_end(f, locker.err, 13, .Medium, CW - 60), card.x + 40, ly, 13, p.hex(lk.error), .Sans, .Medium)
	case locker_caps(app):
		p.fill_circle(cv, card.x + 30, ly - 4.5, 3.5, p.hex(lk.warn))
		p.draw_text(cv, f, "Caps Lock is on", card.x + 40, ly, 13, p.hex(lk.warn), .Sans, .Medium)
	case:
		p.draw_text(cv, f, "Enter to unlock · Esc to clear", card.x + 24, ly, 12.5, p.hex(lk.faint), .Sans)
	}

	// The footer: since when, and which machine.
	lh, lm, _ := time.clock_from_time(locker.locked_wall)
	foot := fmt.tprintf("Locked at %02d:%02d · %s", lh, lm, locker_hostname())
	if lock_abandoned {
		foot = "The lock screen program stopped; the session stays locked"
	}
	fw := p.text_width(f, foot, 12, .Sans)
	p.draw_text(cv, f, foot, cx - fw / 2, area.y + area.h - 28, 12, p.hex(lk.faint), .Sans)
}

locker_hostname :: proc() -> string {
	if data, err := os.read_entire_file("/proc/sys/kernel/hostname", context.temp_allocator); err == nil {
		if h := strings.trim_space(string(data)); h != "" {
			return h
		}
	}
	return "palmy"
}
