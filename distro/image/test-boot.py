"""Boot distro/out/palmframe.img headless and walk it from firmware to desktop.

    python3 -I distro/image/test-boot.py            (make -C distro test runs it)

The image is copied first (sparse) so the test never changes the one that
ships, and enlarged (--grow, 6G by default) the way a person copies it onto
a bigger disk. QEMU is started through distro/run-qemu.sh -- OVMF, limine,
the kernel from the ESP, the ext4 root on /dev/vda2 -- so what is tested is
what a user boots. The screen is read with QMP screendumps (PNG for people, PPM parsed
here, since the build host has no PIL); keys are typed with QMP
input-send-event; the serial console runs busybox getty, and a root shell
there reads the process table and logs and drives palm.

    first boot: / and the ESP fsck'd, the root grown to the disk, the
      ESP on /boot/efi, the time zone, a machine id, zram (or why not)
    the greeter is on screen, as user greeter          -> shots/01-greeter.png
    palm / palm logs in, wm --drm runs as palm         -> shots/02-desktop.png
    SUPER+Return opens term and it runs a command      -> shots/03-term.png
    SUPER+D opens the launcher                         -> shots/04-launcher.png
    palm list --installed, palm verify
    palm update && palm add <a package not installed>, over http from the host
    poweroff ends the machine

Nothing here touches the host's display or seat: QEMU runs with -display none.
"""

import argparse
import functools
import http.server
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DISTRO = os.path.dirname(HERE)


class Machine:
    def __init__(self, img, work):
        self.work = work
        self.serial_path = os.path.join(work, "serial.sock")
        self.qmp_path = os.path.join(work, "qmp.sock")
        for p in (self.serial_path, self.qmp_path):
            if os.path.exists(p):
                os.unlink(p)
        cmd = [os.path.join(DISTRO, "run-qemu.sh"),
               "--serial-socket", self.serial_path, "--qmp-socket", self.qmp_path,
               "--", "-no-reboot"]
        env = dict(os.environ, IMG=img)
        self.proc = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL,
                                     stderr=open(os.path.join(work, "qemu.log"), "w"))
        self.serial = self._connect(self.serial_path)
        self.serial.setblocking(False)
        self.buf = ""
        self.mark = 0
        self.transcript = open(os.path.join(work, "serial.txt"), "w")
        self.failures = []

    def _connect(self, path):
        deadline = time.time() + 15
        while time.time() < deadline:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(path)
                return s
            except OSError:
                time.sleep(0.05)
        raise RuntimeError(f"cannot connect to {path}")

    def _pump(self, wait):
        end = time.time() + wait
        while True:
            try:
                data = self.serial.recv(65536)
                if not data:
                    return False
                text = data.decode("utf-8", "replace").replace("\r", "").replace("\0", "")
                self.buf += text
                self.transcript.write(text)
                self.transcript.flush()
            except BlockingIOError:
                if time.time() >= end:
                    return True
                time.sleep(0.02)
            except OSError:
                return False

    def expect(self, pattern, timeout=30, flags=re.M):
        rx = re.compile(pattern, flags)
        deadline = time.time() + timeout
        while True:
            m = rx.search(self.buf, self.mark)
            if m:
                self.mark = m.end()
                return m
            if time.time() > deadline or (not self._pump(0.1) and self.proc.poll() is not None):
                return None

    def send(self, line):
        self.serial.sendall((line + "\r").encode())

    def run(self, command, timeout=15):
        """Run a shell command on the serial root shell; (output, exit status)."""
        tag = f"@@{int(time.time() * 1000) % 100000}@@"
        self.send(f"echo {tag}B; {command}; echo {tag}E$?")
        m = self.expect(re.escape(tag) + r"B\n(.*?)" + re.escape(tag) + r"E(\d+)\n", timeout, re.S)
        return (m.group(1), int(m.group(2))) if m else ("(timed out)", -1)

    def check(self, what, ok, detail=""):
        print(f"  {'pass' if ok else 'FAIL'}  {what}" +
              (f"\n        {detail.strip()[:1500]}" if detail and not ok else ""), flush=True)
        if not ok:
            self.failures.append(what)
        return ok

    def qmp(self, *commands):
        s = self._connect(self.qmp_path)
        f = s.makefile("rw")
        json.loads(f.readline())
        replies = []
        for cmd in [{"execute": "qmp_capabilities"}] + list(commands):
            f.write(json.dumps(cmd) + "\n")
            f.flush()
            while True:
                r = json.loads(f.readline())
                if "event" in r:
                    continue
                replies.append(r)
                break
        s.close()
        return replies[1:]

    def screen(self, path):
        """Write a PNG to path; return (w, h, rgb) from a PPM taken alongside."""
        ppm = path + ".ppm"
        self.qmp({"execute": "screendump", "arguments": {"filename": ppm}},
                 {"execute": "screendump", "arguments": {"filename": path, "format": "png"}})
        with open(ppm, "rb") as f:
            data = f.read()
        os.unlink(ppm)
        parts = data.split(b"\n", 3)
        w, h = map(int, parts[1].split())
        return w, h, parts[3]

    def key(self, *qcodes):
        ev = lambda q, d: {"type": "key", "data": {"down": d, "key": {"type": "qcode", "data": q}}}
        self.qmp({"execute": "input-send-event", "arguments": {"events": [ev(q, True) for q in qcodes]}})
        time.sleep(0.04)
        self.qmp({"execute": "input-send-event", "arguments": {"events": [ev(q, False) for q in reversed(qcodes)]}})
        time.sleep(0.05)

    def type(self, text):
        names = {" ": "spc", "\n": "ret", "-": "minus", ".": "dot", "/": "slash", "=": "equal",
                 ";": "semicolon", ",": "comma", "'": "apostrophe"}
        shifted = {"|": "backslash", "&": "7", ":": "semicolon", "_": "minus", ">": "dot", "$": "4"}
        for ch in text:
            if ch.isupper():
                self.key("shift", ch.lower())
            elif ch in shifted:
                self.key("shift", shifted[ch])
            else:
                self.key(names.get(ch, ch))

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        self.transcript.close()
        for p in (self.serial_path, self.qmp_path):
            if os.path.exists(p):
                os.unlink(p)


def colours(w, h, rgb):
    seen = set()
    for i in range(0, w * h * 3, 3 * 11):
        seen.add((rgb[i] >> 3, rgb[i + 1] >> 3, rgb[i + 2] >> 3))
        if len(seen) > 4000:
            break
    return len(seen)


def serve(directory, port):
    """The repository over plain http, as `make -C distro serve` serves it."""
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a):
            pass
    handler = functools.partial(Quiet, directory=directory)
    httpd = http.server.ThreadingHTTPServer(("0.0.0.0", port), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def parse_size(s):
    """6G, 512M, 1048576 -> bytes."""
    units = {"K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}
    return int(s[:-1]) * units[s[-1].upper()] if s[-1].upper() in units else int(s)


def wait_for(m, command, pattern, tries=40):
    out = ""
    for _ in range(tries):
        out, _ = m.run(command)
        if re.search(pattern, out, re.M):
            return True, out
        time.sleep(1)
    return False, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default=os.path.join(DISTRO, "out", "palmframe.img"))
    ap.add_argument("--shots", default=os.path.join(DISTRO, "out", "shots"))
    ap.add_argument("--work", default=os.path.join(DISTRO, "build", "integrate"))
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--add", default="shop", help="a package outside the default set to install over http")
    ap.add_argument("--grow", default="6G", help="enlarge the copy to this size first ('' to boot it as built)")
    args = ap.parse_args()
    os.makedirs(args.shots, exist_ok=True)
    os.makedirs(args.work, exist_ok=True)
    img = os.path.join(args.work, "test.img")
    subprocess.run(["cp", "--sparse=always", args.image, img], check=True)
    if args.grow:
        # What a person does with the image: copy it onto a bigger disk.
        before = os.path.getsize(img)
        os.truncate(img, max(before, parse_size(args.grow)))
        print(f"  ....  {img} enlarged from {before >> 20} MiB to {os.path.getsize(img) >> 20} MiB")
    httpd = serve(os.path.join(DISTRO, "out", "repo"), args.port)
    shot = lambda name: os.path.join(args.shots, name)

    print(f"boot: {args.image} (copy in {img})")
    m = Machine(img, args.work)
    t0 = time.time()
    try:
        if not m.check("palm-init starts (firmware, limine, kernel, ext4 root)",
                       m.expect(r"palm-init: Palmframe is starting", 60) is not None):
            return m.failures
        print(f"  ....  palm-init after {time.time() - t0:.1f}s")
        m.check("palm-login started", m.expect(r"palm-init: started palm-login", 30) is not None)
        if not m.check("getty on ttyS0", m.expect(r"palmframe login: ", 40) is not None):
            return m.failures
        m.send("root")
        m.expect(r"Password: ", 10)
        m.send("palm")
        if not m.check("root shell on the serial console", m.expect(r"# ", 15) is not None):
            return m.failures
        m.run("stty -echo cols 200")

        out, _ = m.run("cat /proc/cmdline; readlink /proc/1/exe; grep ' / ' /proc/mounts")
        m.check("root is /dev/vda2 ext4 rw, PID 1 is palm-init",
                "root=/dev/vda2" in out and re.search(r" / ext4 rw", out) is not None and "palm-init" in out, out)

        # --- first boot: fsck, the root grown to the disk, the ESP, swap ---
        boot = m.buf
        m.check("/ checked by e2fsck before it was made writable", "palm-init: checking / (/dev/vda2)" in boot, boot[-3000:])
        m.check("the ESP checked by fsck.fat", "palm-init: checking /boot/efi (/dev/vda1)" in boot, boot[-3000:])
        if args.grow:
            m.check("grow-root grew the root partition", re.search(r"palm-init: grow-root: vda2 now ends at \d+ MiB", boot) is not None, boot[-3000:])
            m.check("grow-root grew ext4 online", re.search(r"palm-init: grow-root: / grown from \d+ MiB to \d+ MiB", boot) is not None, boot[-3000:])
        out, _ = m.run("df -m / /boot/efi; grep -E ' /boot/efi ' /proc/mounts; cat /proc/swaps; ls /etc/palm/grow-root 2>&1; "
                       "readlink /etc/localtime; cat /etc/timezone; date +%Z; cat /etc/machine-id")
        print("  ....  first boot:\n" + "\n".join("          " + l for l in out.strip().splitlines()))
        df = re.search(r"^/dev/\S+\s+(\d+)\s+\d+\s+\d+\s+\d+%\s+/$", out, re.M)
        if args.grow:
            # The disk less the ESP and alignment, less ext4's own inode
            # tables and journal (a few per cent).
            want = ((parse_size(args.grow) >> 20) - 130) * 95 // 100
            m.check(f"df: / fills the {args.grow} disk", df is not None and int(df.group(1)) >= want, f"want >= {want} MiB\n" + out)
            m.check("/etc/palm/grow-root is gone", "No such file" in out, out)
        m.check("/boot/efi is the ESP (vfat)", re.search(r"^/dev/vda1 /boot/efi vfat rw,", out, re.M) is not None, out)
        m.check("/etc/localtime and /etc/timezone agree", re.search(r"zoneinfo/(\S+)\n\1\n", out) is not None, out)
        m.check("a machine id was made", re.search(r"^[0-9a-f]{32}$", out, re.M) is not None, out)
        if "/dev/zram0" in out:
            m.check("zram swap is on", re.search(r"^/dev/zram0\s+partition", out, re.M) is not None, out)
        else:
            m.check("no zram in this kernel: palm-init says so", "palm-init: zram: this kernel has no zram" in boot, boot[-3000:])

        # --- the greeter ---
        ok, out = wait_for(m, "ps -o user,args | grep -E '[g]reeter|[w]m ' || true", r"^\s*greeter\s+(/usr/bin/)?greeter")
        m.check("the greeter runs as user greeter, inside wm --kiosk", ok and "--kiosk" in out, out)
        time.sleep(3)
        w, h, rgb = m.screen(shot("01-greeter.png"))
        n = colours(w, h, rgb)
        print(f"  ....  01-greeter.png {w}x{h}, {n} colours")
        m.check("the greeter is on screen", n > 8)

        # --- log in ---
        m.type("palm\n")
        ok, out = wait_for(m, "ps -o user,args | grep '[w]m --drm' || true", r"^\s*palm\s+wm --drm\s*$")
        m.check("palm / palm starts wm --drm as palm", ok,
                out + m.run("tail -20 /var/log/palm-login.log")[0])
        time.sleep(4)
        w, h, rgb = m.screen(shot("02-desktop.png"))
        print(f"  ....  02-desktop.png {w}x{h}, {colours(w, h, rgb)} colours")

        # --- a terminal ---
        m.key("meta_l", "ret")
        ok, out = wait_for(m, "ps -o user,args | grep '[t]erm' || true", r"^\s*palm\s+(/usr/bin/)?term\b", 20)
        m.check("SUPER+Return starts term as palm", ok, out + m.run("tail -20 /var/log/session-palm.log")[0])
        time.sleep(2)
        m.type("uname -a; id; palm list --installed | head -8; palm verify | tail -1\n")
        time.sleep(2)
        w, h, rgb = m.screen(shot("03-term.png"))
        print(f"  ....  03-term.png {w}x{h}, {colours(w, h, rgb)} colours")

        # --- the launcher lists the installed .desktop entries ---
        m.key("meta_l", "d")
        ok, out = wait_for(m, "ps -o user,args | grep '[l]auncher' || true", r"^\s*palm\s+(/usr/bin/)?launcher", 15)
        m.check("SUPER+D opens the launcher", ok, out)
        time.sleep(2)
        w, h, rgb = m.screen(shot("04-launcher.png"))
        print(f"  ....  04-launcher.png {w}x{h}, {colours(w, h, rgb)} colours")
        m.key("esc")

        # --- palm on the installed system ---
        # The image points at the public repository; the test uses the one
        # this build just made, served from the host.
        LOCAL_REPO = f"http://10.0.2.2:{args.port}/x86_64"
        out, st = m.run("palm list --installed", 30)
        print("  ....  palm list --installed:\n" + "\n".join("          " + l for l in out.strip().splitlines()))
        m.check("palm list --installed lists the 31 shipped packages",
                st == 0 and "palmframe" in out and len(out.strip().splitlines()) >= 31, out)
        out, st = m.run("palm verify", 60)
        print("  ....  palm verify (exit %d):\n" % st + "\n".join("          " + l for l in out.strip().splitlines()[-15:]))
        m.check("palm verify finds nothing wrong", st == 0, out)
        out, st = m.run(f"palm update --repo {LOCAL_REPO}", 60)
        print("  ....  palm update (exit %d): %s" % (st, out.strip().replace("\n", " | ")))
        m.check("palm update fetches the signed index from http://10.0.2.2", st == 0, out)
        out, st = m.run(f"palm add --repo {LOCAL_REPO} --yes {args.add} && command -v {args.add} && palm info {args.add}", 120)
        print(f"  ....  palm add {args.add} (exit {st}):\n" + "\n".join("          " + l for l in out.strip().splitlines()))
        m.check(f"palm add {args.add} installs it over http", st == 0 and f"/usr/bin/{args.add}" in out, out)
        out, st = m.run("palm verify", 60)
        m.check("palm verify is still clean after the add", st == 0, out)

        # --- off ---
        m.send("poweroff")
        m.check("poweroff: palm-init powers off", m.expect(r"palm-init: powering off", 20) is not None)
        try:
            m.proc.wait(30)
            exited = True
        except subprocess.TimeoutExpired:
            exited = False
        m.check("the machine powers off (QEMU exits)", exited)
    finally:
        m.close()
        httpd.shutdown()
    return m.failures


if __name__ == "__main__":
    failures = main()
    print(f"test-boot: {'all passed' if not failures else f'{len(failures)} failed'}")
    sys.exit(1 if failures else 0)
