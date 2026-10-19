package wm

// The lock screen's and the power dialog's checks in wm --selftest. palm-login
// is not running here: login.odin's capture mode records each request and the
// test answers it the way palm-login would (distro/login --selftest checks
// palm-login's side of the same conversation).

import "core:os"
import "core:strings"
import p "palmy:."

locker_selftest :: proc(s: ^Server) {
	// --- lock_after --------------------------------------------------------
	{
		Case :: struct {
			in_:  string,
			secs: int,
			ok:   bool,
		}
		for c in ([]Case{{"90s", 90, true}, {"5m", 300, true}, {"5min", 300, true}, {"1h", 3600, true}, {"300", 300, true}, {"off", 0, true}, {"never", 0, true}, {"soon", 0, false}, {"-5", 0, false}}) {
			secs, ok := cfg_duration(c.in_)
			ws_check(ok == c.ok && (!ok || secs == c.secs), "lock_after = %s reads as %d s (ok %v)", c.in_, secs, ok)
		}
		c: Cfg
		cfg_scalars(&c)
		cfg_parse(&c, CFG_DEFAULT, "<built-in>")
		ws_eq(c.lock_after, 600, "the default locks after ten minutes without input")
		cfg_parse(&c, "lock_after = 2m\n", "t")
		ws_eq(c.lock_after, 120, "lock_after = 2m")
		cfg_parse(&c, "lock_after = whenever\n", "t")
		ws_check(len(c.errors) == 1 && c.lock_after == 120, "a bad lock_after is an error and keeps the old value")
		cfg_destroy(&c)
	}

	// --- no palm-login, no lock --------------------------------------------
	saved_sock := strings.clone(os.get_env("PALM_SESSION_SOCK", context.temp_allocator))
	os.unset_env("PALM_SESSION_SOCK")
	defer if saved_sock != "" {
		os.set_env("PALM_SESSION_SOCK", saved_sock)
	}
	ws_check(!locker_lock(s, "key") && !lock_active(), "without palm-login the session does not lock (it could not be unlocked)")
	ws_check(!power_offered(), "...and Restart and Shut down are not offered")

	login_ipc.capture = true
	defer {
		login_ipc.capture = false
		for x in login_ipc.sent {
			delete(x)
		}
		clear(&login_ipc.sent)
		login_ipc.req = .None
	}
	last_sent :: proc() -> string {
		return len(login_ipc.sent) > 0 ? login_ipc.sent[len(login_ipc.sent) - 1] : ""
	}
	type :: proc(s: ^Server, text: string) {
		for r in text {
			locker_key(s, p.Key_Event{sym = u32(r)})
		}
	}

	// --- the power menu with palm-login --------------------------------------
	{
		items: [dynamic]Menu_Item
		defer menu_items_free(&items)
		start_power_items(s, &items)
		labels := make([dynamic]string, context.temp_allocator)
		for it in items {
			append(&labels, it.label)
		}
		all := strings.join(labels[:], "|", context.temp_allocator)
		ws_check(
			strings.contains(all, "Lock") && strings.contains(all, "Log out…") && strings.contains(all, "Restart…") && strings.contains(all, "Shut down…"),
			"the power menu offers Lock, Log out, Restart and Shut down: %s",
			all,
		)
	}

	// --- locking -------------------------------------------------------------
	ws_check(locker_lock(s, "key") && lock_active() && locker_internal(), "Super+L locks, with the compositor's own prompt")
	{
		// No client gets the keyboard or the pointer while locked.
		fake := new(Surface)
		defer free(fake)
		set_kbd_focus(s, fake)
		ws_check(s.kbd_surf == nil, "a window asking for the keyboard while locked does not get it")
		set_ptr_focus(s, fake, 0, 0)
		ws_check(s.ptr_surf == nil, "...nor the pointer")
	}
	type(s, "palm")
	ws_check(string(locker.pw[:]) == "palm", "typing fills the password field")
	locker_key(s, p.Key_Event{sym = p.KEY_BACKSPACE})
	ws_check(string(locker.pw[:]) == "pal", "Backspace removes a character")
	locker_key(s, p.Key_Event{sym = p.KEY_ESCAPE})
	ws_check(len(locker.pw) == 0, "Esc clears the field")
	type(s, "pä")
	locker_key(s, p.Key_Event{sym = 'u', mods = {.Ctrl}})
	ws_check(len(locker.pw) == 0, "Ctrl+U clears it too (and a non-ASCII character was one entry)")
	locker_key(s, p.Key_Event{sym = p.KEY_RETURN})
	ws_check(len(login_ipc.sent) == 0, "Enter on an empty field asks nothing")

	type(s, "wrong")
	locker_key(s, p.Key_Event{sym = p.KEY_RETURN})
	sent := last_sent()
	ws_check(strings.contains(sent, `"type":"unlock"`) && strings.contains(sent, `"password":"wrong"`), "Enter sends the password to palm-login: %s", sent)
	ws_check(locker.busy && len(locker.pw) == 0, "...the field is emptied and the prompt waits")
	type(s, "x")
	ws_check(len(locker.pw) == 0, "typing while the answer is on its way is ignored")
	login_fake_reply(s, {error_type = "auth_error", description = "The password was not accepted."})
	ws_check(lock_active() && !locker.busy && locker.err == "The password was not accepted.", "a wrong password: still locked, and the error says so")
	type(s, "p")
	ws_check(locker.err == "", "typing again clears the error")
	locker_key(s, p.Key_Event{sym = p.KEY_ESCAPE})
	type(s, "palm")
	locker_key(s, p.Key_Event{sym = p.KEY_RETURN})
	login_fake_reply(s, {error_type = "auth_error", description = "Too many failed attempts. Try again in 12 seconds."})
	ws_check(strings.contains(locker.err, "12 seconds"), "the rate limit's words are shown as they come")
	type(s, "palm")
	locker_key(s, p.Key_Event{sym = p.KEY_RETURN})
	login_fake_reply(s, {error_type = "error", description = "palm-login closed the connection"})
	ws_check(lock_active() && strings.has_prefix(locker.err, "The password cannot be checked"), "palm-login unreachable: still locked, and said so")
	ws_check(locker_lock(s, "key") && lock_active(), "locking an already locked session is harmless")
	type(s, "palm")
	locker_key(s, p.Key_Event{sym = p.KEY_RETURN})
	login_fake_reply(s, {ok = true})
	ws_check(!lock_active() && len(locker.pw) == 0 && locker.err == "", "the right password unlocks, and nothing of it is kept")

	// A client locker (ext_session_lock_v1) that died leaves the session
	// locked (lock.odin); the compositor's prompt is what opens it again.
	{
		lock_state = .Locked
		lock_abandoned = true
		ws_check(locker_internal(), "an abandoned client lock shows the compositor's prompt")
		type(s, "palm")
		locker_key(s, p.Key_Event{sym = p.KEY_RETURN})
		ws_check(strings.contains(last_sent(), `"type":"unlock"`), "...which asks palm-login")
		login_fake_reply(s, {ok = true})
		ws_check(!lock_active() && !lock_abandoned, "...and the password unlocks it")
	}

	// --- idle --------------------------------------------------------------
	{
		app: p.App
		saved := s.cfg.lock_after
		defer s.cfg.lock_after = saved
		s.cfg.lock_after = 60
		locker.last_input = wall_now() - 30
		locker_tick(s, &app)
		ws_check(!lock_active(), "half the idle time: not locked")
		append(&lock_idle_list, Lock_Idle{client = nil, id = 1})
		locker.last_input = wall_now() - 61
		locker_tick(s, &app)
		ws_check(!lock_active(), "an idle inhibitor (a video) holds the idle lock off")
		clear(&lock_idle_list)
		locker.last_input = wall_now() - 61
		locker_tick(s, &app)
		ws_check(lock_active() && locker.why == "idle", "lock_after without input locks")
		type(s, "palm")
		locker_key(s, p.Key_Event{sym = p.KEY_RETURN})
		login_fake_reply(s, {ok = true})
		s.cfg.lock_after = 0
		locker.last_input = wall_now() - 100000
		locker_tick(s, &app)
		ws_check(!lock_active(), "lock_after = off never locks")
	}

	// --- Restart and Shut down -------------------------------------------------
	{
		// No windows: the earlier checks' windows are not clients that
		// could answer a close.
		saved_stack := s.stack
		s.stack = {}
		defer {
			delete(s.stack)
			s.stack = saved_stack
		}
		power_open(s, "poweroff")
		sent = last_sent()
		ws_check(power.phase == .Confirm && power.check == .Pending, "Shut down asks first")
		ws_check(strings.contains(sent, `"action":"poweroff","dry_run":true`), "...and palm-login is asked, as a dry run, before anything closes: %s", sent)
		power_key(s, p.Key_Event{sym = p.KEY_ESCAPE})
		ws_check(power.phase == .None, "Esc cancels")
		login_fake_reply(s, {ok = true})
		ws_check(power.phase == .None, "a late answer to a cancelled dialog changes nothing")

		power_open(s, "reboot")
		login_fake_reply(s, {ok = true})
		ws_check(power.check == .Ok, "palm-login allows it")
		power.deadline = max(wall_now() - 0.1, 1e-6)
		power_tick(s)
		ws_check(power.phase == .Sending && strings.contains(last_sent(), `"action":"reboot","dry_run":false`), "the countdown runs out: windows closed, then the request: %s (phase %v, open %v)", last_sent(), power.phase, power_open_windows(s))
		login_fake_reply(s, {ok = true})
		ws_check(power.quit, "palm-login agrees: the wm leaves, and palm-login does the rest")
		power_reset()

		power_open(s, "poweroff")
		login_fake_reply(s, {error_type = "auth_required", description = "Someone else is logged in (root on ttyS0). Enter your password to shut down anyway."})
		ws_check(power.phase == .Password && power.deadline == 0, "someone else logged in: a password is asked, and the countdown stops")
		for r in "palm" {
			power_key(s, p.Key_Event{sym = u32(r)})
		}
		power_key(s, p.Key_Event{sym = p.KEY_RETURN})
		ws_check(strings.contains(last_sent(), `"dry_run":true,"password":"palm"`), "...the password goes as a dry run first")
		login_fake_reply(s, {error_type = "auth_error", description = "The password was not accepted."})
		ws_check(power.phase == .Password && power.err != "", "a wrong one is said so, and asked again")
		for r in "palm" {
			power_key(s, p.Key_Event{sym = u32(r)})
		}
		power_key(s, p.Key_Event{sym = p.KEY_RETURN})
		login_fake_reply(s, {ok = true})
		ws_check(power.phase == .Sending && strings.contains(last_sent(), `"dry_run":false,"password":"palm"`), "the right one: the request carries it: %s (%v)", last_sent(), power.phase)
		ws_check(len(power.pw) == 0, "...and the dialog forgets it")
		login_fake_reply(s, {error_type = "error", description = "the session is not the one on screen"})
		ws_check(power.phase == .Failed && power.msg == "the session is not the one on screen", "a refusal is shown in palm-login's words")
		power_key(s, p.Key_Event{sym = p.KEY_RETURN})
		ws_check(power.phase == .None, "and Close closes it")

		power_open(s, "logout")
		ws_check(power.check == .Ok && len(login_ipc.sent) > 0 && !strings.contains(last_sent(), "logout"), "Log out needs nobody's permission")
		power_key(s, p.Key_Event{sym = p.KEY_TAB})
		ws_check(power.sel == 0, "Tab moves to Cancel")
		power_key(s, p.Key_Event{sym = p.KEY_RETURN})
		ws_check(power.phase == .None, "and Enter on Cancel cancels")

		power_open(s, "poweroff")
		ws_check(locker_lock(s, "key") && power.phase == .None, "locking cancels a power dialog")
		login_fake_reply(s, {ok = true}) // the dialog's dry run, answered late
		ws_check(lock_active(), "...and its late answer does not unlock anything")
		type(s, "palm")
		locker_key(s, p.Key_Event{sym = p.KEY_RETURN})
		login_fake_reply(s, {ok = true})
		ws_check(!lock_active(), "unlocked again")
	}
	power_reset()
}
