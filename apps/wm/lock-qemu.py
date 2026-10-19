"""The lock screen and the session's power actions on the built image.

    python3 -I apps/wm/lock-qemu.py [--image distro/out/palmframe.img] [--out DIR]

Three boots of one disk (QEMU runs with -no-reboot, so a restart ends a
boot; the logs on the disk say what happened before it):

  boot 1  palm logs in at the greeter; PALM_SESSION_SOCK and the session
          socket (palm's, 0600); Super+L locks: nothing of the desktop is
          drawn, the keyboard reaches no client (what is typed while locked
          does not reach the focused terminal); a wrong password is refused,
          late; the right one unlocks; Ctrl+Alt+F2 and back while locked
          lands on the lock; lock_after locks an idle session; then root
          logs out of the serial console, and Restart from the start menu,
          left to its countdown, reboots: "palm-init: rebooting".
  boot 2  boot 1's logs: the terminal was asked to close, the wm left,
          palm-login closed the session, then ran /sbin/reboot, in that
          order. Then, root logged in on the serial console, Shut down asks
          for palm's password (palm is in wheel), refuses a wrong one, takes
          the right one and powers off: "palm-init: powering off".
  boot 3  boot 2's logs: the override, the session closed, /sbin/poweroff.
"""
import argparse
import importlib.util
import os
import re
import subprocess
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location("testboot", os.path.join(ROOT, "distro/image/test-boot.py"))
tb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tb)


class M(tb.Machine):
    size = (1280, 800)

    def events(self, evs):
        self.qmp({"execute": "input-send-event", "arguments": {"events": evs}})

    def move(self, x, y):
        w, h = self.size
        self.events([{"type": "abs", "data": {"axis": "x", "value": int(x * 0x7FFF / max(w - 1, 1))}},
                     {"type": "abs", "data": {"axis": "y", "value": int(y * 0x7FFF / max(h - 1, 1))}}])
        time.sleep(0.06)

    def click(self, x, y):
        self.move(x, y)
        self.events([{"type": "btn", "data": {"down": True, "button": "left"}}])
        time.sleep(0.06)
        self.events([{"type": "btn", "data": {"down": False, "button": "left"}}])
        time.sleep(0.15)


def row_colours(w, rgb, y):
    seen = set()
    for x in range(0, w, 2):
        i = (y * w + x) * 3
        seen.add((rgb[i] >> 2, rgb[i + 1] >> 2, rgb[i + 2] >> 2))
    return len(seen)


def log_count(m, pattern):
    out, _ = m.run(f"grep -c '{pattern}' /var/log/session-palm.log || true")
    try:
        return int(out.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return -1


def root_login(m):
    assert m.expect(r"palmframe login: ", 120), "no getty"
    m.send("root")
    m.expect(r"Password: ", 10)
    m.send("palm")
    assert m.expect(r"# ", 15), "no root shell"
    m.run("stty -echo cols 200")


def in_order(text, patterns):
    """The offsets of the patterns' first matches, each after the one before."""
    at, out = 0, []
    for pat in patterns:
        mm = re.compile(pat).search(text, at)
        if not mm:
            out.append(-1)
            return False, out
        out.append(mm.start())
        at = mm.end()
    return True, out


def boot_to_desktop(m, shot):
    root_login(m)
    palm_login(m, shot)
    return M.size


def palm_login(m, shot):
    tb.wait_for(m, "ps -o user,args | grep -E '[g]reeter' || true", r"greeter")
    time.sleep(3)
    m.type("palm\n")
    ok, out = tb.wait_for(m, "ps -o user,args | grep '[w]m --drm' || true", r"^\s*palm\s+wm --drm\s*$")
    m.check("palm's session: wm --drm as palm", ok, out)
    time.sleep(4)
    w, h, rgb = m.screen(shot("desktop.png"))
    M.size = (w, h)


def open_power_menu(m):
    """Super opens the start menu; its footer's last button is power."""
    m.key("meta_l")
    time.sleep(0.7)
    # start.odin: the menu is 640x612 at (8, bar + 8); the power button is
    # 36 px square, 14 px from the right edge, centred in the 62 px footer.
    x = 8 + 640 - 14 - 18
    y = 34 + 8 + 612 - 62 + 31
    m.click(x, y)
    time.sleep(0.5)


def boot1(args, img, shot):
    m = M(img, os.path.join(args.work, "boot1"))
    try:
        boot_to_desktop(m, lambda n: shot("b1-01-" + n))
        env, _ = m.run("cat /proc/$(pgrep -x wm | head -1)/environ | tr '\\0' '\\n' | grep PALM_SESSION_SOCK")
        m.check("the session is told where palm-login's session socket is",
                "PALM_SESSION_SOCK=/run/palm-login.session.sock" in env, env)
        ls, _ = m.run("stat -c '%U %a' /run/palm-login.session.sock")
        m.check("the session socket is palm's, 0600, while palm is logged in", ls.strip() == "palm 600", ls)

        # A terminal with the keyboard, so a key that leaked would run.
        m.key("meta_l", "ret")
        ok, out = tb.wait_for(m, "ps -o user,args | grep -E '^palm +(/usr/bin/)?term' || true", r"term", 15)
        m.check("Super+Return opens a terminal (focused)", ok, out)
        time.sleep(2)
        m.run("rm -f /tmp/leak")
        w, h, before = m.screen(shot("b1-02-term.png"))
        bar_before = row_colours(w, before, 17)

        # --- Super+L ---------------------------------------------------------
        m.key("meta_l", "l")
        time.sleep(1)
        w, h, locked = m.screen(shot("b1-03-locked.png"))
        m.check("Super+L locks", log_count(m, "session locked (key)") == 1)
        bar_now = row_colours(w, locked, 17)
        m.check("nothing of the desktop is drawn: the bar's row is the lock's plain background",
                bar_before > 6 and bar_now <= 4, f"distinct colours in row 17: {bar_before} before, {bar_now} locked")

        # What is typed while locked is the lock's: the terminal never sees it.
        m.type("echo leak >/tmp/leak\n")
        time.sleep(2.5)
        out, _ = m.run("ls /tmp/leak 2>&1")
        m.check("keys typed while locked do not reach the focused terminal", "No such file" in out, out)

        # A wrong password: refused, and late.
        time.sleep(3.5)  # the earlier "password" counted as a failure
        m.type("nope\n")
        t0 = time.time()
        early = log_count(m, "unlock refused")
        m.screen(shot("b1-04-checking.png"))
        ok = False
        for _ in range(30):
            if log_count(m, "unlock refused") >= 2:
                ok = True
                break
            time.sleep(0.2)
        took = time.time() - t0
        m.check("a wrong password is refused", ok)
        m.check("...not at once (palm-login holds the answer)", early == 1, f"refusals right after Enter: {early}, answered after ~{took:.1f}s")
        m.screen(shot("b1-05-wrong.png"))
        plog, _ = m.run("grep 'session: authentication failure' /var/log/palm-login.log | tail -2")
        m.check("palm-login counted the failures (faillock, shared with doas)", "in a row" in plog, plog)

        # The right one, once the rate limit lets it through.
        time.sleep(7)
        m.type("palm\n")
        ok = False
        for _ in range(30):
            if log_count(m, "session unlocked") >= 1:
                ok = True
                break
            time.sleep(0.3)
        m.check("the right password unlocks", ok)
        time.sleep(1)
        w, h, after = m.screen(shot("b1-06-unlocked.png"))
        m.check("...and the desktop is back", row_colours(w, after, 17) > 6)

        # --- a VT switch while locked -----------------------------------------
        m.key("meta_l", "l")
        time.sleep(1)
        m.key("ctrl", "alt", "f2")
        time.sleep(1.5)
        vt, _ = m.run("cat /sys/class/tty/tty0/active")
        m.check("Ctrl+Alt+F2 while locked switches to tty2", vt.strip() == "tty2", vt)
        m.key("ctrl", "alt", "f1")
        time.sleep(2)
        vt, _ = m.run("cat /sys/class/tty/tty0/active")
        w, h, back = m.screen(shot("b1-07-vt-back.png"))
        m.check("...and Ctrl+Alt+F1 comes back to the lock, still locked",
                vt.strip() == "tty1" and row_colours(w, back, 17) <= 4 and log_count(m, "session unlocked") == 1,
                f"vt {vt.strip()}, row colours {row_colours(w, back, 17)}")
        m.type("palm\n")
        for _ in range(30):
            if log_count(m, "session unlocked") >= 2:
                break
            time.sleep(0.3)
        m.check("unlocked again", log_count(m, "session unlocked") == 2)

        # --- idle ----------------------------------------------------------------
        m.run("mkdir -p /home/palm/.config/palmy && echo 'lock_after = 12s' >> /home/palm/.config/palmy/wm.conf && chown -R palm:palm /home/palm/.config")
        time.sleep(17)
        w, h, idle = m.screen(shot("b1-08-idle.png"))
        m.check("lock_after = 12s locks an idle session", log_count(m, "session locked (idle)") == 1 and row_colours(w, idle, 17) <= 4)
        m.run("sed -i '/^lock_after/d' /home/palm/.config/palmy/wm.conf")
        m.type("palm\n")
        for _ in range(30):
            if log_count(m, "session unlocked") >= 3:
                break
            time.sleep(0.3)
        m.check("and unlocks with the password", log_count(m, "session unlocked") == 3)
        time.sleep(1.5)

        # --- Restart, alone on the machine, left to its countdown ---------------
        m.send("exit")  # root leaves the serial console: nobody else is logged in
        assert m.expect(r"palmframe login: ", 20), "root did not log out"
        open_power_menu(m)
        m.screen(shot("b1-09-power-menu.png"))
        m.type("r")  # Restart… (the first item starting with r)
        time.sleep(1.2)
        m.screen(shot("b1-10-restart-confirm.png"))
        t0 = time.time()
        ok = m.expect(r"palm-init: rebooting", 40)
        took = time.time() - t0 + 1.2
        m.check("left alone, the countdown runs out and the machine restarts: palm-init: rebooting", ok is not None)
        m.check("...after the ten-second countdown, not at once", ok is not None and 9 < took < 25, f"{took:.1f}s")
        try:
            m.proc.wait(30)
        except subprocess.TimeoutExpired:
            pass
        m.check("QEMU exits (-no-reboot)", m.proc.poll() is not None)
    finally:
        m.close()
    return m.failures


def boot2(args, img, shot):
    m = M(img, os.path.join(args.work, "boot2"))
    try:
        root_login(m)
        log, _ = m.run("cat /var/log/palm-login.log", 20)
        ok, at = in_order(log, [r'"palm" asked for reboot from the session', r'user session of "palm" ended \(exit 0\)',
                                r'session of "palm" closed', r'the session has ended; running reboot', r'running /sbin/reboot'])
        m.check("boot 1's restart, by palm-login's log: asked from the session, the session ended by itself, closed, then /sbin/reboot", ok, f"{at}\n{log[-1500:]}")
        slog, _ = m.run("grep -E '^wm: (reboot|palm-login will)' /var/log/session-palm.log", 20)
        ok, at = in_order(slog, [r"wm: reboot asked for; confirming", r"wm: reboot: asked 1 window\(s\) to close",
                                 r"wm: palm-login will reboot once the session ends; leaving"])
        m.check("...and by the wm's: confirmed, the terminal asked to close, then palm-login asked", ok, f"{at}\n{slog}")

        palm_login(m, lambda n: shot("b2-01-" + n))
        m.send("setsid sh -c 'exec tail -n0 -f /var/log/palm-login.log /var/log/session-palm.log' </dev/null >/dev/console 2>&1 &")
        time.sleep(0.5)
        who, _ = m.run("who")
        m.check("root is logged in on the serial console", "ttyS0" in who, who)
        open_power_menu(m)
        m.type("s")  # Shut down…
        time.sleep(1.5)
        m.screen(shot("b2-02-shutdown-password.png"))
        m.check("Shut down… opens the dialog", m.expect(r"wm: poweroff asked for", 5) is not None)
        m.type("nope\n")
        ok = m.expect(r"session: authentication failure", 10)
        m.check("someone else is logged in: a password is asked, and a wrong one refused", ok is not None)
        time.sleep(0.6)
        m.screen(shot("b2-03-shutdown-wrong.png"))
        time.sleep(1.5)
        m.type("palm\n")
        ok = m.expect(r"palm-init: powering off", 40)
        m.check("palm's password (palm is in wheel) overrides, and the machine powers off: palm-init: powering off", ok is not None)
        try:
            m.proc.wait(30)
        except subprocess.TimeoutExpired:
            pass
        m.check("QEMU exits", m.proc.poll() is not None)
    finally:
        m.close()
    return m.failures


def boot3(args, img, shot):
    m = M(img, os.path.join(args.work, "boot3"))
    try:
        root_login(m)
        log, _ = m.run("cat /var/log/palm-login.log", 20)
        tail = log[log.rfind('"palm" overrode') - 400:] if '"palm" overrode' in log else log[-2000:]
        ok, at = in_order(tail, [r'session: authentication failure for "palm"', r'"palm" overrode the other logins \(root on ttyS0\)',
                                 r'"palm" asked for poweroff from the session', r'session of "palm" closed', r'running /sbin/poweroff'])
        m.check("boot 2's shutdown, by palm-login's log: the wrong password, the override, the request, the session closed, /sbin/poweroff", ok, f"{at}\n{tail[-1500:]}")
        m.send("poweroff")
        m.expect(r"palm-init: powering off", 30)
    finally:
        m.close()
    return m.failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default=os.path.join(ROOT, "distro/out/palmframe.img"))
    ap.add_argument("--out", default=os.path.join(ROOT, "distro/build/lock-qemu/shots"))
    ap.add_argument("--work", default=os.path.join(ROOT, "distro/build/lock-qemu"))
    ap.add_argument("--only", default="", help="1, 2 or 3: one boot (2 and 3 continue the disk the one before left)")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    shot = lambda name: os.path.join(args.out, name)
    failures = []
    img = os.path.join(args.work, "test.img")
    if not args.only or args.only == "1":
        subprocess.run(["cp", "--sparse=always", args.image, img], check=True)
        os.truncate(img, max(os.path.getsize(img), 4 << 30))
    for n, boot in ((1, boot1), (2, boot2), (3, boot3)):
        if args.only and str(n) != args.only:
            continue
        os.makedirs(os.path.join(args.work, f"boot{n}"), exist_ok=True)
        print(f"=== boot {n}")
        failures += boot(args, img, shot)
    print(f"{len(failures)} failure(s): {failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
