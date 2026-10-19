"""Notifications on the disk image, in QEMU: the daemon from session.d, the
session bus, a toast on the real window manager, quiet then a digest, a call
breaking through, and the sound.

    python3 -I apps/notify/qemu-test.py [--image distro/out/palmy.img]

The image must have the notify package installed (it is in the default set
once distro/apps/default.list names it). It reuses distro/image/test-boot.py's
Machine: OVMF, limine, the serial console as root, QMP for keys and
screendumps; nothing touches the host's display.
"""

import argparse
import importlib.util
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DISTRO = os.path.join(ROOT, "distro")

spec = importlib.util.spec_from_file_location("testboot", os.path.join(DISTRO, "image", "test-boot.py"))
tb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tb)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default=os.path.join(DISTRO, "out", "palmy.img"))
    ap.add_argument("--shots", default=os.path.join(DISTRO, "out", "shots"))
    ap.add_argument("--work", default=os.path.join(DISTRO, "build", "notify-qemu"))
    args = ap.parse_args()
    os.makedirs(args.shots, exist_ok=True)
    os.makedirs(args.work, exist_ok=True)
    img = os.path.join(args.work, "test.img")
    os.system(f"cp --sparse=always '{args.image}' '{img}'")
    shot = lambda name: os.path.join(args.shots, name)

    m = tb.Machine(img, args.work)
    try:
        m.check("palm-init starts", m.expect(r"palm-init: Palmy is starting", 90) is not None)
        if not m.check("getty on ttyS0", m.expect(r"palmy login: ", 90) is not None):
            return m.failures
        m.send("root")
        m.expect(r"Password: ", 10)
        m.send("palm")
        m.expect(r"# ", 15)
        m.run("stty -echo cols 250")

        ok, out = tb.wait_for(m, "ps -o user,args | grep -E '[g]reeter' || true", r"greeter")
        m.check("the greeter is up", ok, out)
        time.sleep(3)
        m.type("palm\n")
        ok, out = tb.wait_for(m, "ps -o user,args | grep '[w]m --drm' || true", r"^\s*palm\s+wm --drm")
        m.check("palm logs in: wm --drm as palm", ok, out)

        # --- what session.d started -------------------------------------------
        ok, out = tb.wait_for(m, "ps -o user,args | grep -E '[n]otify daemon|[d]bus-daemon --session' || true",
                              r"notify daemon[\s\S]*|dbus-daemon --session", 20)
        out, _ = m.run("ps -o user,args | grep -E '[n]otify daemon|[d]bus-daemon --session|[p]ipewire'")
        print("  ....  session processes:\n" + "\n".join("          " + l for l in out.strip().splitlines()))
        m.check("session.d/45-dbus-session: a session bus runs as palm",
                re.search(r"^\s*palm\s+dbus-daemon --session", out, re.M) is not None, out)
        m.check("session.d/60-notify: palm-notifyd runs as palm",
                re.search(r"^\s*palm\s+notify daemon", out, re.M) is not None, out)

        env, _ = m.run("cat /proc/$(pgrep -f 'notify daemon' | head -1)/environ | tr '\\0' '\\n' | grep -E '^(XDG_RUNTIME_DIR|HOME)='")
        rt = re.search(r"XDG_RUNTIME_DIR=(\S+)", env)
        rt = rt.group(1) if rt else "/run/user/1000"
        # busybox su keeps root's environment: give palm its own HOME, or the
        # center would read /root/.config for the identity registry.
        P = f"su -s /bin/sh palm -c 'export HOME=/home/palm XDG_RUNTIME_DIR={rt} PALM_THEME=light; "

        def palm(cmd, timeout=20):
            return m.run(P + cmd.replace("'", "'\\''") + "'", timeout)

        time.sleep(2)
        out, st = palm("notify status --json")
        print("  ....  notify status:\n" + "\n".join("          " + l for l in out.strip().splitlines()))
        m.check("notify status answers as palm", st == 0 and '"socket"' in out, out)
        m.check("palm-notifyd owns org.freedesktop.Notifications on the session bus",
                '"bus": "org.freedesktop.Notifications"' in out, out)
        out, st = palm(f"dbus-send --bus=unix:path={rt}/bus --print-reply --dest=org.freedesktop.Notifications "
                       "/org/freedesktop/Notifications org.freedesktop.Notifications.GetServerInformation")
        m.check("a freedesktop client on the image reaches it (GetServerInformation)", "Palmy" in out, out)

        # --- a toast on the real window manager -----------------------------------
        # The identity registry Accounts writes: names and colours.
        reg = ('[{"handle":"camille","name":"Personal","color":"teal"},'
               '{"handle":"camille.roux","name":"Northwind","color":"blue"}]')
        m.run("mkdir -p /home/palm/.config/palmy; printf '%s' '" + reg + "' > /home/palm/.config/palmy/identities.json; "
              "chown -R palm /home/palm/.config")
        palm("notify quiet set --identity camille.roux 'calls break through'")
        out, st = palm("PALM_IDENTITY=camille notify send --app chat --class person 'Priya Shah' "
                       "'Are we still on for dinner on Saturday?' --action 'reply=Reply' --json")
        m.check("a person's message is a toast", '"delivery": "toast"' in out, out)
        out, st = palm("notify send --identity camille.roux --app calendar --class time 'Design review in 10 min' "
                       "'Room 2 · Northwind' --json")
        ok, out = tb.wait_for(m, "ps -o user,args | grep '[n]otify toasts' || true", r"notify toasts", 20)
        m.check("the daemon started the toast surface on wm", ok,
                out + palm("tail -5 /var/log/session-palm.log 2>/dev/null")[0])
        time.sleep(3)
        w, h, rgb = m.screen(shot("notify-01-toasts.png"))
        print(f"  ....  notify-01-toasts.png {w}x{h}, {tb.colours(w, h, rgb)} colours")
        m.check("toasts on screen", tb.colours(w, h, rgb) > 8)

        out, _ = palm("notify status --json")
        snd = re.search(r'"sounds_played": (\d+)', out)
        m.check("a sound was played through PipeWire", snd is not None and int(snd.group(1)) > 0 and "pw-play" in out, out)

        # --- the keyboard ------------------------------------------------------------
        out, _ = palm("notify focus --json")
        m.check("notify focus: the toasts take the keyboard", '"toasts"' in out, out)
        time.sleep(2)
        m.key("down")
        time.sleep(1)
        w, h, rgb = m.screen(shot("notify-02-keyboard.png"))
        m.key("delete")
        time.sleep(1.5)
        out, _ = palm("notify list --json")
        m.check("Down, Delete dismissed the second toast from the keyboard",
                re.search(r'"title": "Priya Shah"[\s\S]*?"read": true', out) is not None or
                re.search(r'"read": true[\s\S]*?"title": "Priya Shah"', out) is not None, out[-1500:])
        m.key("esc")

        # --- quiet, a call that breaks through, then the digest ------------------------
        palm("notify quiet set --identity camille.roux 'quiet for 2 hours. calls break through'")
        out, _ = palm("notify send --identity camille.roux --app mail --class person 'Ines Roux' 'Moved the review to Thursday' --json")
        m.check("Northwind quiet: a person is held", '"delivery": "digest"' in out, out)
        out, _ = palm("notify send --identity camille.roux --app call --class person --urgency critical "
                      "--category call.incoming 'Ines Roux' 'Incoming call' --action 'answer=Answer|decline=Decline' --json")
        m.check("a call breaks through, because the sentence says so", '"delivery": "toast"' in out and "calls break through" in out, out)
        time.sleep(3)
        m.screen(shot("notify-03-call.png"))
        palm("notify quiet set --identity camille.roux 'calls break through'")
        time.sleep(3)
        out, _ = palm("notify list --identity camille.roux --json")
        m.check("quiet lifted: the held one goes out as a digest", "1 notification while quiet" in out, out[-2000:])
        time.sleep(1)
        m.screen(shot("notify-04-digest.png"))

        # --- the center ---------------------------------------------------------------
        palm("setsid notify center >/dev/null 2>&1 < /dev/null &")
        time.sleep(4)
        w, h, rgb = m.screen(shot("notify-05-center.png"))
        print(f"  ....  notify-05-center.png {w}x{h}, {tb.colours(w, h, rgb)} colours")
        out, _ = m.run("ps -o user,args | grep '[n]otify center' || true")
        m.check("the center runs on wm", "notify center" in out, out)
        m.key("esc")
        time.sleep(1)
        out, _ = palm("cat " + rt + "/palm/notify.state")
        print("  ....  notify.state:\n" + "\n".join("          " + l for l in out.strip().splitlines()))
        m.check("the bar's state file is there", out.startswith("unread "), out)
    finally:
        m.close()
    print()
    print(f"notify-qemu: {len(m.failures)} failure(s)")
    for f in m.failures:
        print("  FAIL", f)
    return m.failures


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
