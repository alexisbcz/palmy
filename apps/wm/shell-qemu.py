"""Drive the shell on the built image: the start menu by Super and by click,
search and launch, pin, the desktop menu's Settings, a setting that visibly
applies, and every default application started once.

    python3 -I apps/wm/shell-qemu.py [--image distro/out/palmframe.img] [--out DIR]
"""
import argparse
import importlib.util
import os
import re
import subprocess
import sys
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
        ax = int(x * 0x7FFF / max(w - 1, 1))
        ay = int(y * 0x7FFF / max(h - 1, 1))
        self.events([{"type": "abs", "data": {"axis": "x", "value": ax}},
                     {"type": "abs", "data": {"axis": "y", "value": ay}}])
        time.sleep(0.06)

    def click(self, x, y, btn="left"):
        self.move(x, y)
        self.events([{"type": "btn", "data": {"down": True, "button": btn}}])
        time.sleep(0.06)
        self.events([{"type": "btn", "data": {"down": False, "button": btn}}])
        time.sleep(0.15)

    def wheel(self, down=True, n=3):
        b = "wheel-down" if down else "wheel-up"
        for _ in range(n):
            self.events([{"type": "btn", "data": {"down": True, "button": b}}])
            self.events([{"type": "btn", "data": {"down": False, "button": b}}])
            time.sleep(0.05)


def pix(rgb, w, x, y):
    i = (y * w + x) * 3
    return rgb[i], rgb[i + 1], rgb[i + 2]


def luma(c):
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default=os.path.join(ROOT, "distro/out/palmframe.img"))
    ap.add_argument("--out", default=os.path.join(ROOT, "distro/build/shell-qemu/shots"))
    ap.add_argument("--work", default=os.path.join(ROOT, "distro/build/shell-qemu"))
    ap.add_argument("--apps", default="")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    os.makedirs(args.work, exist_ok=True)
    img = os.path.join(args.work, "test.img")
    subprocess.run(["cp", "--sparse=always", args.image, img], check=True)
    os.truncate(img, max(os.path.getsize(img), 4 << 30))
    shot = lambda name: os.path.join(args.out, name)

    m = M(img, args.work)
    try:
        assert m.expect(r"palmframe login: ", 120), "no getty"
        m.send("root")
        m.expect(r"Password: ", 10)
        m.send("palm")
        assert m.expect(r"# ", 15), "no root shell"
        m.run("stty -echo cols 200")
        ok, out = tb.wait_for(m, "ps -o user,args | grep -E '[g]reeter' || true", r"greeter")
        time.sleep(3)
        m.type("palm\n")
        ok, out = tb.wait_for(m, "ps -o user,args | grep '[w]m --drm' || true", r"^\s*palm\s+wm --drm\s*$")
        m.check("palm's session: wm --drm as palm", ok, out)
        time.sleep(4)
        w, h, rgb = m.screen(shot("01-desktop.png"))
        M.size = (w, h)
        print(f"  ....  screen {w}x{h}")
        env, _ = m.run("cat /proc/$(pgrep -x wm | head -1)/environ | tr '\\0' '\\n' | grep -E '^(XDG_RUNTIME_DIR|HOME|USER|PATH)='")
        rt = re.search(r"XDG_RUNTIME_DIR=(\S+)", env)
        rt = rt.group(1) if rt else "/run/user/1000"
        sock, _ = m.run(f"ls {rt} | grep -E '^wayland-[0-9a-z-]+$' | grep -v lock | head -1")
        sock = sock.strip() or "wayland-1"
        state, _ = m.run(f"cat {rt}/palmy-wm.json")
        m.check("the wm publishes its state for Settings", '"outputs"' in state and '"keyboard"' in state, state)
        print("  ....  " + state.strip()[:300])
        as_palm = lambda cmd: f"su palm -s /bin/sh -c 'exec env -i HOME=/home/palm USER=palm LOGNAME=palm PATH=/usr/bin:/bin XDG_RUNTIME_DIR={rt} WAYLAND_DISPLAY={sock} /bin/sh -c \"{cmd}\"'"

        # --- the start menu by Super --------------------------------------
        bar_before = pix(rgb, w, 300, 300)
        m.key("meta_l")
        time.sleep(0.6)
        w, h, rgb2 = m.screen(shot("02-start-super.png"))
        changed = sum(1 for x in range(20, 600, 37) for y in range(60, 600, 41) if pix(rgb, w, x, y) != pix(rgb2, w, x, y))
        m.check("a tap of Super opens the start menu", changed > 40, f"{changed} sample points changed")

        # Type to search and launch.
        m.type("sett")
        time.sleep(0.4)
        m.screen(shot("03-start-search.png"))
        m.key("ret")
        ok, out = tb.wait_for(m, "ps -o user,args | grep '[s]ettings' || true", r"palm\s+(/usr/bin/)?settings", 15)
        m.check("typing 'sett' + Return starts Settings", ok, out)
        time.sleep(2.5)
        m.screen(shot("04-settings.png"))

        # Change the look from Settings itself: click the Light card.
        # (The Appearance page opens first; the Light preview is the right
        # half of the Style card.)
        out, _ = m.run(as_palm("settings get appearance.theme"))
        print("  ....  theme before: " + out.strip())
        m.run(as_palm("settings set appearance.theme light"))
        time.sleep(1.8)
        w, h, rgb3 = m.screen(shot("05-light.png"))
        top = luma(pix(rgb3, w, w // 2, 6))
        m.check("settings set appearance.theme light turns the bar light within a second", top > 200, f"bar luma {top:.0f}")
        out, _ = m.run("cat /home/palm/.config/palmy/wm.conf")
        print("  ....  wm.conf:\n" + "\n".join("          " + l for l in out.strip().splitlines()))
        m.key("ctrl", "q")
        time.sleep(1)

        # --- the start menu by click -----------------------------------------
        m.click(40, 17)
        time.sleep(0.6)
        w, h, rgb4 = m.screen(shot("06-start-click-light.png"))
        changed = sum(1 for x in range(20, 600, 37) for y in range(60, 600, 41) if pix(rgb3, w, x, y) != pix(rgb4, w, x, y))
        m.check("clicking the Palmframe button opens the start menu", changed > 40, f"{changed} sample points changed")

        # All apps, and pin one to the bar from its menu.
        m.click(560, 134)  # All apps ›
        time.sleep(0.5)
        m.screen(shot("07-all-apps.png"))
        m.click(200, 200, "right")  # the first app row
        time.sleep(0.4)
        m.screen(shot("08-app-menu.png"))
        m.key("down")
        m.key("down")
        m.key("down")
        m.screen(shot("08b-app-menu-sel.png"))
        m.key("esc")
        m.key("esc")
        m.key("esc")
        time.sleep(0.3)
        # Pin through the keyboard: open, search "calc", Menu key, choose "Pin to bar".
        m.key("meta_l")
        time.sleep(0.5)
        m.type("calc")
        time.sleep(0.3)
        m.key("shift", "f10")
        time.sleep(0.3)
        m.screen(shot("09-pin-menu.png"))
        m.type("p")  # first item starting with p: Pin to Start (or Unpin...), then Pin to bar
        time.sleep(0.4)
        out, _ = m.run("cat /home/palm/.config/palmy/pinned 2>&1; echo ---; cat /home/palm/.config/palmy/pinned-bar 2>&1")
        m.check("pinning from the start menu writes ~/.config/palmy/pinned", "calc.desktop" in out, out)
        for _ in range(3):
            m.key("esc")
        time.sleep(0.3)
        m.screen(shot("10-after-pin.png"))

        # --- the desktop menu: Settings is there now --------------------------
        m.click(900, 600, "right")
        time.sleep(0.5)
        m.screen(shot("11-desktop-menu.png"))
        # Settings is the last item: Up from the top wraps to it.
        m.key("up")
        time.sleep(0.2)
        m.screen(shot("11b-desktop-menu-settings.png"))
        m.key("ret")
        ok, out = tb.wait_for(m, "ps -o user,args | grep '[s]ettings' || true", r"palm\s+(/usr/bin/)?settings", 15)
        m.check("the desktop menu's Settings opens Settings", ok, out)
        time.sleep(2.5)
        m.screen(shot("12-settings-from-desktop.png"))
        # Natural scrolling through Settings' own setter, then back to dark.
        m.run(as_palm("settings set mouse.natural_scroll on"))
        m.run(as_palm("settings set appearance.theme dark"))
        time.sleep(1.8)
        w, h, rgb5 = m.screen(shot("13-dark-again.png"))
        top = luma(pix(rgb5, w, w // 2, 6))
        m.check("and back to dark", top < 60, f"bar luma {top:.0f}")
        log, _ = m.run("grep -c 'config' /var/log/session-palm.log; tail -5 /var/log/session-palm.log")
        print("  ....  session log: " + log.strip()[-400:])
        m.key("ctrl", "q")
        time.sleep(1)

        # --- every default application, once ------------------------------------
        apps = args.apps.split() if args.apps else []
        if not apps:
            out, _ = m.run("ls /usr/share/applications | sed 's/.desktop$//' | tr '\\n' ' '")
            apps = out.split()
        print(f"  ....  {len(apps)} launchable entries: {' '.join(apps)}")
        for app in apps:
            exe, _ = m.run(f"sed -n 's/^Exec=\\([^ ]*\\).*/\\1/p' /usr/share/applications/{app}.desktop")
            exe = exe.strip()
            if not exe:
                continue
            m.run(as_palm(f"{exe} >/tmp/app-{app}.log 2>&1 &"))
            time.sleep(3)
            alive, _ = m.run(f"ps -o user,args | grep -E '^palm +(/usr/bin/)?{exe}( |$)' >/dev/null && echo alive || echo dead")
            log, _ = m.run(f"tail -3 /tmp/app-{app}.log")
            ok = "alive" in alive
            m.screen(shot(f"app-{app}.png"))
            m.check(f"{app}: starts and stays up", ok, log)
            m.run(f"pkill -x {exe}; true")
            time.sleep(0.8)
    finally:
        print(f"{len(m.failures)} failure(s): {m.failures}")
        m.close()


if __name__ == "__main__":
    main()
