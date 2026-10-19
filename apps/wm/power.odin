// power.odin — Restart, Shut down and Log out from the session.
//
// The start menu's power menu opens a confirmation, the way every desktop
// does it: what will happen, a ten-second countdown, Cancel, and the action
// now. Then:
//
//   1. every window is asked to close (xdg_toplevel.close, what its own
//      close button does), and the wm waits for them to go, up to eight
//      seconds;
//   2. one that is still open after that is named ("Notes is still open; it
//      may be asking to save") and the person decides: Cancel to go and see,
//      or do it anyway;
//   3. for Restart and Shut down, palm-login is asked over the session
//      socket (login.odin; distro/login/session_ipc.odin): it checks that the
//      request comes from this session, then the wm exits, palm-login tears
//      the session down as it does for any logout (utmp, the tty, the
//      session's process group) and only then runs /sbin/poweroff or
//      /sbin/reboot. Log out needs nobody: the wm exits.
//
// palm-login is asked first, with a dry run, when the dialog opens, so a
// refusal is on screen before anything is closed: someone else logged in on
// another line (palm-login then asks a member of wheel for their password,
// as logind asks an admin), or the request not coming from the session on
// screen.
package wm

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import ai "kit:appindex"
import p "palmy:."

POWER_COUNTDOWN :: 10.0 // s
POWER_CLOSE_WAIT :: 8.0 // s for windows to close before they are named

Power_Phase :: enum u8 {
	None,
	Confirm, // the question and the countdown (modal)
	Password, // someone else is logged in: a wheel member's password (modal)
	Closing, // windows asked to close; a small card, the windows usable
	Waiting, // some did not close: Cancel or anyway (modal)
	Sending, // palm-login has the request
	Failed, // palm-login said no, or could not be asked (modal)
}

Power_Check :: enum u8 {
	Pending,
	Ok,
	Refused,
}

Power_State :: struct {
	phase:      Power_Phase,
	action:     string, // "poweroff", "reboot", "logout" (static strings)
	opened_at:  f64,
	deadline:   f64, // the countdown's end; 0 when it is stopped
	check:      Power_Check,
	msg:        string, // palm-login's words (owned)
	err:        string, // a wrong password (owned)
	pw:         [dynamic]u8, // zeroed whenever dropped
	pw_ok:      bool, // pw passed the dry run and rides on the real request
	sel:        int, // 0 Cancel, 1 the action
	closing_at: f64,
	cancel_r:   p.Rect,
	action_r:   p.Rect,
	quit:       bool, // tests: the wm would have exited here
}

power: Power_State

power_active :: proc() -> bool {
	return power.phase != .None
}

// power_modal: the dialog has the keyboard and the pointer.
power_modal :: proc() -> bool {
	#partial switch power.phase {
	case .Confirm, .Password, .Waiting, .Failed:
		return true
	}
	return false
}

// power_offered: may this session restart and shut down the machine?
power_offered :: proc() -> bool {
	return login_available() && !session.kiosk
}

power_open :: proc(s: ^Server, action: string) {
	if session.kiosk || lock_active() {
		return
	}
	if action != "logout" && !login_available() {
		toast(s, "Restart and Shut down need palm-login, which is not running this session")
		return
	}
	start_close(s)
	menu_close(s)
	power_reset()
	now := wall_now()
	power.phase = .Confirm
	power.action = action
	power.opened_at = now
	power.deadline = now + POWER_COUNTDOWN
	power.sel = 1
	power.check = .Ok
	if action != "logout" {
		power.check = .Pending
		if login_busy() && login_ipc.req != .Unlock {
			login_close() // an earlier dialog's question; its answer no longer matters
		}
		sb := login_power_payload(action, true, "")
		if ok, why := login_send(.Power_Check, strings.to_string(sb)); !ok {
			power_fail(fmt.tprintf("palm-login cannot be asked: %s.", why))
		}
	}
	fmt.printfln("wm: %s asked for; confirming", action)
	s.dirty = true
}

power_reset :: proc() {
	login_zero(power.pw[:])
	clear(&power.pw)
	delete(power.msg)
	delete(power.err)
	pw := power.pw
	power = {}
	power.pw = pw
}

power_cancel :: proc(s: ^Server) {
	if power.phase == .None || power.phase == .Sending {
		return
	}
	fmt.printfln("wm: %s cancelled", power.action)
	power_reset()
	s.dirty = true
}

power_fail :: proc(msg: string) {
	login_zero(power.pw[:])
	clear(&power.pw)
	delete(power.msg)
	power.msg = strings.clone(msg)
	power.phase = .Failed
	power.check = .Refused
	power.deadline = 0
	power.sel = 0
}

power_on_reply :: proc(s: ^Server, req: Login_Req, r: Login_Reply) {
	if power.phase == .None {
		return
	}
	if req == .Power {
		if r.ok {
			fmt.printfln("wm: palm-login will %s once the session ends; leaving", power.action)
			power_exit(s)
			return
		}
		power_fail(r.description != "" ? r.description : "palm-login refused.")
		return
	}
	// The dry run.
	switch {
	case r.ok:
		power.check = .Ok
		if power.phase == .Password {
			power.pw_ok = true
			power_begin_closing(s)
		}
	case r.error_type == "auth_required":
		power.check = .Refused
		power.phase = .Password
		power.deadline = 0
		power.sel = 1
		delete(power.msg)
		power.msg = strings.clone(r.description)
	case r.error_type == "auth_error" && power.phase == .Password:
		delete(power.err)
		power.err = strings.clone(r.description)
		login_zero(power.pw[:])
		clear(&power.pw)
	case:
		power_fail(r.description != "" ? r.description : "palm-login refused.")
	}
}

// power_begin_closing asks every window to close.
power_begin_closing :: proc(s: ^Server) {
	power.phase = .Closing
	power.closing_at = wall_now()
	power.deadline = 0
	n := 0
	for t in s.stack {
		if t.client != nil && !t.client.dead {
			event(t.client, t.id, 1) // xdg_toplevel.close
			client_flush(t.client)
			n += 1
		}
	}
	fmt.printfln("wm: %s: asked %d window(s) to close", power.action, n)
	power_tick(s)
}

// power_open_windows lists the windows still there, by title.
power_open_windows :: proc(s: ^Server) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for t in s.stack {
		if t.client != nil && !t.client.dead && t.mapped {
			append(&out, title_of(t))
		}
	}
	return out[:]
}

power_send :: proc(s: ^Server) {
	if power.action == "logout" {
		power_exit(s)
		return
	}
	pw := power.pw_ok ? string(power.pw[:]) : ""
	sb := login_power_payload(power.action, false, pw)
	ok, why := login_send(.Power, strings.to_string(sb))
	login_zero(sb.buf[:])
	login_zero(power.pw[:])
	clear(&power.pw)
	if !ok {
		power_fail(fmt.tprintf("palm-login cannot be asked: %s.", why))
		return
	}
	power.phase = .Sending
}

// power_exit leaves: the session ends, and palm-login does the rest.
power_exit :: proc(s: ^Server) {
	power.quit = true
	power.phase = .Sending
	if menu_app != nil && !login_ipc.capture {
		p.quit_app(menu_app)
	}
}

// power_tick runs the countdown and watches the windows go.
power_tick :: proc(s: ^Server) {
	now := wall_now()
	#partial switch power.phase {
	case .Confirm:
		if power.deadline > 0 {
			if now >= power.deadline && power.check == .Ok {
				power_begin_closing(s)
				return
			}
			// Wake for the next whole second of the countdown.
			left := power.deadline - now
			wake_at(now + (left - f64(int(left))) + 0.01)
		}
	case .Closing:
		if len(power_open_windows(s)) == 0 {
			power_send(s)
			return
		}
		if now - power.closing_at >= POWER_CLOSE_WAIT {
			power.phase = .Waiting
			power.sel = 0
			s.dirty = true
			return
		}
		wake_at(power.closing_at + POWER_CLOSE_WAIT)
	}
}

power_activate :: proc(s: ^Server) {
	#partial switch power.phase {
	case .Confirm:
		if power.sel == 0 {
			power_cancel(s)
		} else if power.check == .Ok {
			power_begin_closing(s)
		} else {
			// Still waiting for palm-login's answer: go as soon as it comes.
			power.deadline = wall_now()
		}
	case .Password:
		if power.sel == 0 {
			power_cancel(s)
			return
		}
		if len(power.pw) == 0 || login_busy() {
			return
		}
		sb := login_power_payload(power.action, true, string(power.pw[:]))
		ok, why := login_send(.Power_Check, strings.to_string(sb))
		login_zero(sb.buf[:])
		if !ok {
			power_fail(fmt.tprintf("palm-login cannot be asked: %s.", why))
			return
		}
		delete(power.err)
		power.err = ""
	case .Waiting:
		if power.sel == 0 {
			power_cancel(s)
		} else {
			power_send(s)
		}
	case .Failed:
		power_cancel(s)
	}
	s.dirty = true
}

// power_key: the dialog's keys. Modal phases take every key.
power_key :: proc(s: ^Server, k: p.Key_Event) -> bool {
	if !power_modal() {
		return false
	}
	s.dirty = true
	switch k.sym {
	case p.KEY_ESCAPE:
		power_cancel(s)
		return true
	case p.KEY_RETURN, KEY_KP_ENTER:
		power_activate(s)
		return true
	case p.KEY_TAB, KEY_ISO_LEFT_TAB, p.KEY_LEFT, p.KEY_RIGHT:
		if power.phase != .Failed {
			power.sel = 1 - power.sel
		}
		return true
	}
	if power.phase == .Password {
		if k.sym == p.KEY_BACKSPACE {
			if .Ctrl in k.mods {
				login_zero(power.pw[:])
				clear(&power.pw)
			} else if len(power.pw) > 0 {
				_, w := utf8.decode_last_rune(power.pw[:])
				w = max(w, 1)
				login_zero(power.pw[len(power.pw) - w:])
				resize(&power.pw, len(power.pw) - w)
			}
			return true
		}
		if k.mods & {.Ctrl, .Alt, .Super} != {} {
			return true
		}
		if r, ok := key_rune(k.sym); ok && r >= 0x20 && len(power.pw) < LOCK_PW_MAX {
			b, n := utf8.encode_rune(r)
			append(&power.pw, ..b[:n])
			power.sel = 1
		}
	}
	return true
}

// power_pointer: the buttons; the rest of the screen is inert while the
// dialog is modal.
power_pointer :: proc(s: ^Server, app: ^p.App, in_: ^p.Input, mp: [2]int) -> bool {
	if power.phase == .None || power.phase == .Sending {
		return false
	}
	px, py := f32(mp.x), f32(mp.y)
	on_cancel := p.rect_contains(power.cancel_r, px, py)
	on_action := p.rect_contains(power.action_r, px, py) && power.phase != .Failed && power.phase != .Closing
	if in_.pressed[.Left] {
		if on_cancel {
			power.sel = 0
			power_activate(s)
			if power.phase == .Closing {
				power_cancel(s)
			}
			s.dirty = true
			return true
		}
		if on_action {
			power.sel = 1
			power_activate(s)
			return true
		}
	}
	if power.phase == .Closing {
		return false // the windows stay usable: one may be asking to save
	}
	return true
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

power_words :: proc(action: string) -> (title, verb_now, verb_anyway, gerund: string, icon: p.Icon) {
	switch action {
	case "reboot":
		return "Restart?", "Restart now", "Restart anyway", "restart", ai.ICON_ROTATE_CCW
	case "logout":
		return "Log out?", "Log out now", "Log out anyway", "log out", ai.ICON_LOG_OUT
	}
	return "Shut down?", "Shut down now", "Shut down anyway", "shut down", ai.ICON_POWER
}

// power_wrap breaks `text` into lines no wider than `w`.
power_wrap :: proc(f: ^p.Fonts, text: string, size: f32, w: f32) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	line := strings.builder_make(context.temp_allocator)
	for word in strings.fields(text, context.temp_allocator) {
		try := strings.builder_len(line) == 0 ? word : fmt.tprintf("%s %s", strings.to_string(line), word)
		if strings.builder_len(line) > 0 && p.text_width(f, try, size, .Sans) > w {
			append(&lines, strings.clone(strings.to_string(line), context.temp_allocator))
			strings.builder_reset(&line)
			strings.write_string(&line, word)
		} else {
			strings.builder_reset(&line)
			strings.write_string(&line, try)
		}
	}
	if strings.builder_len(line) > 0 {
		append(&lines, strings.to_string(line))
	}
	return lines[:]
}

power_button :: proc(cv: ^p.Canvas, f: ^p.Fonts, r: p.Rect, label: string, primary, focused, danger: bool) {
	fill := primary ? (danger ? u32(0xdc2626) : pal.accent) : pal.pop_bg
	text := primary ? (danger ? u32(0xffffff) : pal.on_accent) : pal.pop_text
	if focused {
		p.stroke_round_rect(cv, p.rect_inset(r, -3), {10, 10, 10, 10}, 2, p.hex(primary ? fill : pal.accent))
	}
	p.fill_round_rect(cv, r, {8, 8, 8, 8}, p.hex(fill))
	if !primary {
		p.stroke_round_rect(cv, r, {8, 8, 8, 8}, 1, p.hex(pal.pop_line))
	}
	tw := p.text_width(f, label, 13.5, .Sans, .Medium)
	p.draw_text(cv, f, label, r.x + (r.w - tw) / 2, r.y + r.h / 2 + 5, 13.5, p.hex(text), .Sans, .Medium)
}

power_draw :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas) {
	if power.phase == .None {
		return
	}
	f := &app.fonts
	o := out_primary()
	area := p.Rect{0, 0, f32(cv.w), f32(cv.h)}
	if o != nil {
		area = {f32(o.x), f32(o.y), f32(o.w), f32(o.h)}
	}
	title, now_label, anyway_label, gerund, icon := power_words(power.action)
	danger := power.action == "poweroff"
	wm_reset_clip(cv)

	if power.phase == .Closing || power.phase == .Sending {
		// A small card at the bottom: the windows stay usable, one of them
		// may be asking whether to save.
		msg := power.phase == .Sending ? fmt.tprintf("Waiting to %s…", gerund) : fmt.tprintf("Closing apps, then %s…", power.action == "reboot" ? "restarting" : power.action == "logout" ? "logging out" : "shutting down")
		tw := p.text_width(f, msg, 13.5, .Sans, .Medium)
		w := tw + 40 + (power.phase == .Closing ? 96 : 0)
		r := p.Rect{area.x + (area.w - w) / 2, area.y + area.h - 96, w, 52}
		p.drop_shadow(cv, r, {12, 12, 12, 12}, 24, 0, {0, 8}, p.rgba(0, 0, 0, pal.dark ? 150 : 50))
		p.fill_round_rect(cv, r, {12, 12, 12, 12}, p.hex(pal.pop_bg))
		p.stroke_round_rect(cv, r, {12, 12, 12, 12}, 1, p.hex(pal.pop_line))
		p.draw_text(cv, f, msg, r.x + 20, r.y + 31, 13.5, p.hex(pal.pop_text), .Sans, .Medium)
		power.action_r = {}
		power.cancel_r = {}
		if power.phase == .Closing {
			power.cancel_r = {r.x + r.w - 96, r.y + 10, 82, 32}
			power_button(cv, f, power.cancel_r, "Cancel", false, false, false)
		}
		return
	}

	// The modal dialog over a scrim.
	p.fill_rect(cv, {0, 0, f32(cv.w), f32(cv.h)}, p.rgba(0, 0, 0, pal.dark ? 160 : 110))
	W :: f32(460)
	body := make([dynamic]string, context.temp_allocator)
	left := max(0, power.deadline - wall_now())
	secs := int(left + 0.999)
	switch power.phase {
	case .Confirm:
		switch power.action {
		case "logout":
			append(&body, fmt.tprintf("You will be logged out in %d second%s.", secs, secs == 1 ? "" : "s"))
		case "reboot":
			append(&body, fmt.tprintf("Palmy will restart in %d second%s.", secs, secs == 1 ? "" : "s"))
		case:
			append(&body, fmt.tprintf("Palmy will shut down in %d second%s.", secs, secs == 1 ? "" : "s"))
		}
		append(&body, "Open apps are asked to close first, so they can save your work.")
	case .Password:
		title = power.action == "reboot" ? "Restart anyway?" : "Shut down anyway?"
		append(&body, power.msg)
	case .Waiting:
		title = "Apps are still open"
		wins := power_open_windows(s)
		names := strings.join(wins[:min(len(wins), 3)], ", ", context.temp_allocator)
		if len(wins) > 3 {
			names = fmt.tprintf("%s and %d more", names, len(wins) - 3)
		}
		append(&body, fmt.tprintf("%s did not close. %s may be asking whether to save your work.", names, len(wins) == 1 ? "It" : "They"))
		append(&body, fmt.tprintf("Cancel to go back to %s, or %s anyway and lose what is unsaved.", len(wins) == 1 ? "it" : "them", gerund))
	case .Failed:
		title = power.action == "reboot" ? "Cannot restart" : power.action == "logout" ? "Cannot log out" : "Cannot shut down"
		append(&body, power.msg)
	case .None, .Closing, .Sending:
	}
	lines := make([dynamic]string, context.temp_allocator)
	for para in body {
		append(&lines, ..power_wrap(f, para, 13.5, W - 48 - 52))
	}
	H := 24 + 30 + f32(len(lines)) * 20 + 22 + 40 + 24 + 20
	if power.phase == .Password {
		H += 70
	}
	r := p.Rect{area.x + (area.w - W) / 2, area.y + (area.h - H) / 2, W, H}
	p.drop_shadow(cv, r, {14, 14, 14, 14}, 40, 0, {0, 16}, p.rgba(0, 0, 0, pal.dark ? 160 : 60))
	p.fill_round_rect(cv, r, {14, 14, 14, 14}, p.hex(pal.pop_bg))
	p.stroke_round_rect(cv, r, {14, 14, 14, 14}, 1, p.hex(pal.pop_line))

	// The icon in a tinted circle, the title, the words.
	ic := danger ? u32(0xdc2626) : pal.accent
	p.fill_circle(cv, r.x + 24 + 18, r.y + 24 + 18, 18, p.hex(mix(ic, pal.pop_bg, pal.dark ? 0.75 : 0.85)))
	p.draw_icon(cv, wm_icons(), icon, r.x + 24 + 8, r.y + 24 + 8, 20, p.hex(ic))
	tx := r.x + 24 + 52
	p.draw_text(cv, f, title, tx, r.y + 24 + 22, 18, p.hex(pal.pop_text), .Sans, .Semibold)
	y := r.y + 24 + 30 + 18
	for l in lines {
		p.draw_text(cv, f, l, tx, y, 13.5, p.hex(pal.pop_dim), .Sans)
		y += 20
	}

	if power.phase == .Password {
		y += 10
		field := p.Rect{tx, y, W - (tx - r.x) - 24, 40}
		p.fill_round_rect(cv, field, {8, 8, 8, 8}, p.hex(pal.pop_field))
		p.stroke_round_rect(cv, field, {8, 8, 8, 8}, 1, p.hex(power.err != "" ? 0xdc2626 : pal.accent))
		ty := field.y + field.h / 2
		n := utf8.rune_count(string(power.pw[:]))
		if login_busy() {
			p.draw_text(cv, f, "Checking…", field.x + 12, ty + 5, 13.5, p.hex(pal.pop_faint), .Sans)
		} else if n == 0 {
			p.fill_rect(cv, {field.x + 12, ty - 9, 2, 18}, p.hex(pal.accent))
			p.draw_text(cv, f, "Your password", field.x + 20, ty + 5, 13.5, p.hex(pal.pop_faint), .Sans)
		} else {
			dots := min(n, int((field.w - 36) / 12))
			for i in 0 ..< dots {
				p.fill_circle(cv, field.x + 16 + f32(i) * 12, ty, 3.5, p.hex(pal.pop_text))
			}
			p.fill_rect(cv, {field.x + 16 + f32(dots) * 12 - 3, ty - 9, 2, 18}, p.hex(pal.accent))
		}
		y += field.h + 18
		if power.err != "" {
			p.draw_text(cv, f, power.err, tx, y, 12.5, p.hex(0xdc2626), .Sans, .Medium)
		} else if locker_caps(app) {
			p.draw_text(cv, f, "Caps Lock is on", tx, y, 12.5, p.hex(pal.dark ? 0xfbbf24 : 0xb45309), .Sans, .Medium)
		}
		y += 4
	}

	// The buttons, right-aligned: Cancel, then the action.
	by := r.y + r.h - 24 - 40
	label := now_label
	#partial switch power.phase {
	case .Password:
		label = power.action == "reboot" ? "Restart" : "Shut down"
	case .Waiting:
		label = anyway_label
	}
	if power.phase == .Failed {
		power.action_r = {}
		power.cancel_r = {r.x + r.w - 24 - 96, by, 96, 40}
		power_button(cv, f, power.cancel_r, "Close", true, true, false)
	} else {
		aw := p.text_width(f, label, 13.5, .Sans, .Medium) + 36
		power.action_r = {r.x + r.w - 24 - aw, by, aw, 40}
		power.cancel_r = {power.action_r.x - 10 - 96, by, 96, 40}
		power_button(cv, f, power.cancel_r, "Cancel", false, power.sel == 0, false)
		power_button(cv, f, power.action_r, label, true, power.sel == 1, danger)
	}
	if power.phase == .Confirm && power.check == .Pending {
		p.draw_text(cv, f, "Asking palm-login…", r.x + 24, by + 25, 12, p.hex(pal.pop_faint), .Sans)
	}
}
