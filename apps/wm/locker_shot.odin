package wm

// `wm --shots`: the lock screen and the power dialog, dark and light.
//
// The person and the identity are fixtures under /tmp, never the machine's;
// palm-login's answers are made up by login.odin's capture mode, so nothing
// is asked of anything and nothing is shut down.

import "core:fmt"
import "core:os"
import "core:strings"
import p "palmy:."

lock_shots :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas, off: ^p.Offscreen, dir: string, n: ^int) {
	saved := [?]string{"USER", "XDG_CONFIG_HOME", "PALM_CLOUD_DIR"}
	old: [len(saved)]string
	for k, i in saved {
		old[i] = strings.clone(os.get_env(k, context.temp_allocator))
	}
	tmp := fmt.aprintf("/tmp/wm-lock-shots-%d", os.get_pid())
	defer {
		for k, i in saved {
			if old[i] == "" {
				os.unset_env(k)
			} else {
				os.set_env(k, old[i])
			}
		}
		os.remove_all(tmp)
		login_ipc.capture = false
		for x in login_ipc.sent {
			delete(x)
		}
		clear(&login_ipc.sent)
		login_ipc.req = .None
		locker.caps_test = false
		if lock_active() {
			lock_clear(s)
		}
		power_reset()
	}
	mk :: proc(path: string, text := "") {
		_ = os.make_directory_all(path[:strings.last_index_byte(path, '/')])
		_ = os.write_entire_file(path, transmute([]byte)text)
	}
	mk(fmt.tprintf("%s/config/palmframe/identities.json", tmp), `[{"handle":"northwind","display_name":"Northwind","color":"blue"}]`)
	mk(fmt.tprintf("%s/cloud/current", tmp), "northwind\n")
	os.set_env("USER", "camille")
	os.set_env("XDG_CONFIG_HOME", fmt.tprintf("%s/config", tmp))
	login_ipc.capture = true

	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, out) {
			n^ += 1
			fmt.printfln("  %s", out)
		}
	}
	step :: proc(s: ^Server, app: ^p.App, cv: ^p.Canvas) {
		draw(s, app, cv)
		free_all(context.temp_allocator)
	}
	type :: proc(s: ^Server, text: string) {
		for r in text {
			locker_key(s, p.Key_Event{sym = u32(r)})
		}
	}

	for light in ([2]bool{false, true}) {
		suffix := light ? "light" : "dark"
		s.cfg.light = light
		pal_apply(light, s.cfg.accent)
		s.cfg.border_unfocus = light ? 0xd4d4d8 : 0x27272a
		s.bg_w = -1
		// The identity only in the dark set: the light one is a machine
		// with no Palmframe account.
		if light {
			os.set_env("PALM_CLOUD_DIR", fmt.tprintf("%s/none", tmp))
		} else {
			os.set_env("PALM_CLOUD_DIR", fmt.tprintf("%s/cloud", tmp))
		}

		// Locked, the password half typed.
		locker_lock(s, "key")
		type(s, "correct h")
		step(s, app, cv)
		shot(off, dir, fmt.tprintf("20-lock-%s", suffix), n)

		// A wrong password, with Caps Lock on.
		locker_key(s, p.Key_Event{sym = p.KEY_RETURN})
		step(s, app, cv)
		shot(off, dir, fmt.tprintf("21-lock-checking-%s", suffix), n)
		login_fake_reply(s, {error_type = "auth_error", description = "The password was not accepted."})
		locker.caps_test = true
		step(s, app, cv)
		shot(off, dir, fmt.tprintf("22-lock-wrong-caps-%s", suffix), n)
		locker.caps_test = false
		locker_key(s, p.Key_Event{sym = p.KEY_ESCAPE})
		step(s, app, cv)
		shot(off, dir, fmt.tprintf("23-lock-empty-%s", suffix), n)
		lock_clear(s)

		// Shut down: the question and its countdown, over the desktop.
		power_open(s, "poweroff")
		login_fake_reply(s, {ok = true})
		power.deadline = wall_now() + 7.5
		step(s, app, cv)
		shot(off, dir, fmt.tprintf("24-power-confirm-%s", suffix), n)
		power_reset()

		power_open(s, "reboot")
		login_fake_reply(s, {ok = true})
		power.deadline = wall_now() + 9.5
		step(s, app, cv)
		shot(off, dir, fmt.tprintf("25-restart-confirm-%s", suffix), n)
		power_reset()

		// Someone else is logged in: a password, as an admin.
		power_open(s, "poweroff")
		login_fake_reply(s, {error_type = "auth_required", description = "Someone else is logged in (root on ttyS0). Enter your password to shut down anyway."})
		for r in "pal" {
			power_key(s, p.Key_Event{sym = u32(r)})
		}
		step(s, app, cv)
		shot(off, dir, fmt.tprintf("26-power-password-%s", suffix), n)
		power_reset()

		// Windows asked to close; then the ones that did not.
		power_open(s, "poweroff")
		login_fake_reply(s, {ok = true})
		power.phase = .Closing
		power.closing_at = wall_now()
		step(s, app, cv)
		shot(off, dir, fmt.tprintf("27-power-closing-%s", suffix), n)
		power.phase = .Waiting
		power.sel = 0
		step(s, app, cv)
		shot(off, dir, fmt.tprintf("28-power-apps-open-%s", suffix), n)
		power_reset()

		// palm-login said no.
		power_open(s, "reboot")
		login_fake_reply(s, {error_type = "error", description = "the session is not the one on screen"})
		step(s, app, cv)
		shot(off, dir, fmt.tprintf("29-power-refused-%s", suffix), n)
		power_reset()
	}
	s.cfg.light = false
	pal_apply(false, s.cfg.accent)
	s.cfg.border_unfocus = 0x27272a
	s.bg_w = -1
}
