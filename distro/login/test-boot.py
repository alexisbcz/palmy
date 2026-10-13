"""Boot palm-init + palm-login + greeter + wm in QEMU and log in. See test-boot.sh.

The screen is read with QMP screendump (PPM, parsed here: no PIL on the build
host; a PNG of each step is written too, for people to look at). Keys are
typed with QMP input-send-event. The serial console runs busybox getty, and a
root shell there is how the logs and the process table are read.
"""

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time


class Machine:
    def __init__(self, args, name, append):
        self.dir = args.work
        self.name = name
        self.serial_path = os.path.join(self.dir, f"{name}.serial.sock")
        self.qmp_path = os.path.join(self.dir, f"{name}.qmp.sock")
        for p in (self.serial_path, self.qmp_path):
            if os.path.exists(p):
                os.unlink(p)
        cmd = [
            "qemu-system-x86_64",
            "-enable-kvm", "-cpu", "host", "-m", "2G", "-smp", "4",
            "-kernel", args.kernel, "-initrd", args.initrd,
            "-append", append,
            "-device", "virtio-vga",
            "-device", "virtio-keyboard-pci", "-device", "virtio-tablet-pci",
            "-nic", "user,model=virtio-net-pci",
            "-display", "none", "-no-reboot",
            "-serial", f"unix:{self.serial_path},server=on,wait=on",
            "-qmp", f"unix:{self.qmp_path},server=on,wait=off",
            "-monitor", "none",
        ]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                     stderr=open(os.path.join(self.dir, f"{name}.qemu.log"), "w"))
        self.serial = self._connect(self.serial_path)
        self.serial.setblocking(False)
        self.buf = ""
        self.mark = 0
        self.transcript = open(os.path.join(self.dir, f"{name}.transcript.txt"), "w")
        self.failures = []
        self.shots = 0

    def _connect(self, path):
        deadline = time.time() + 10
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

    def run(self, command, timeout=10):
        tag = f"@@{int(time.time() * 1000) % 100000}@@"
        self.send(f"echo {tag}B; {command}; echo {tag}E")
        m = self.expect(re.escape(tag) + r"B\n(.*?)" + re.escape(tag) + r"E\n", timeout, re.S)
        return m.group(1) if m else ""

    def check(self, what, ok, detail=""):
        print(f"  {'pass' if ok else 'FAIL'}  {what}" + (f"  ({detail.strip()[:600]})" if detail and not ok else ""), flush=True)
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

    def screen(self, label):
        """Screendump as PPM (parsed) and PNG (for people). Returns (w, h, rgb)."""
        self.shots += 1
        base = os.path.join(os.path.abspath(self.dir), f"{self.shots:02d}-{label}")
        self.qmp({"execute": "screendump", "arguments": {"filename": base + ".ppm"}},
                 {"execute": "screendump", "arguments": {"filename": base + ".png", "format": "png"}})
        with open(base + ".ppm", "rb") as f:
            data = f.read()
        os.unlink(base + ".ppm")
        # P6\n<w> <h>\n<max>\n<bytes>
        parts = data.split(b"\n", 3)
        w, h = map(int, parts[1].split())
        return w, h, parts[3]

    def key(self, *qcodes):
        down = [{"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": q}}} for q in qcodes]
        up = [{"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": q}}} for q in reversed(qcodes)]
        self.qmp({"execute": "input-send-event", "arguments": {"events": down}})
        time.sleep(0.03)
        self.qmp({"execute": "input-send-event", "arguments": {"events": up}})
        time.sleep(0.05)

    def type(self, text):
        for ch in text:
            if ch == "\n":
                self.key("ret")
            else:
                self.key(ch)

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        self.transcript.close()
        for p in (self.serial_path, self.qmp_path):
            if os.path.exists(p):
                os.unlink(p)


def stats(w, h, rgb):
    """How much of the screen is not black, and how many distinct colours."""
    lit = 0
    colours = set()
    step = 7
    n = 0
    for i in range(0, w * h * 3, 3 * step):
        r, g, b = rgb[i], rgb[i + 1], rgb[i + 2]
        n += 1
        if r + g + b > 24:
            lit += 1
        if len(colours) < 4096:
            colours.add((r >> 3, g >> 3, b >> 3))
    return lit / max(n, 1), len(colours)


def login(args):
    print("login: the greeter on screen, a wrong password, the right one, the session")
    m = Machine(args, "login", "console=ttyS0 rdinit=/sbin/init panic=-1")
    try:
        if not m.check("palm-init starts", m.expect(r"palm-init: Palmframe is starting", 30) is not None):
            return m.failures
        m.check("palm-login service started", m.expect(r"palm-init: started palm-login", 30) is not None)
        if not m.check("getty on ttyS0", m.expect(r"palmframe login: ", 40) is not None):
            return m.failures
        m.send("root")
        m.expect(r"Password: ", 10)
        m.send("palm")
        if not m.check("root shell on the serial console", m.expect(r"# ", 15) is not None):
            return m.failures

        # Wait for the greeter: the screen goes from black (or a console) to
        # the dark login card, and `greeter` runs as the greeter account.
        greeter_up = False
        for _ in range(30):
            out = m.run("ps -o user,comm | grep -E 'greeter|wm' || true")
            if re.search(r"greeter\s+greeter", out):
                greeter_up = True
                break
            time.sleep(1)
        m.check("the greeter runs as user greeter", greeter_up, m.run("ps -o user,args"))
        out = m.run("cat /var/log/palm-login.log")
        m.check("palm-login started the greeter session", "as \"greeter\"" in out, out)
        time.sleep(3)
        w, h, rgb = m.screen("greeter")
        lit, colours = stats(w, h, rgb)
        print(flush=True, end=""); print(f"  ....  screen {w}x{h}, {lit:.0%} lit, {colours} colours")
        m.check("the greeter fills the screen with something", colours > 8, f"{colours} colours")

        out = m.run("tr '\\0' '\\n' < /proc/$(pidof greeter)/environ | grep -E 'GREETD_SOCK|PALM_LOGIN|XDG_RUNTIME_DIR|WAYLAND_DISPLAY'")
        m.check("greeter env: GREETD_SOCK, PALM_LOGIN, XDG_RUNTIME_DIR, WAYLAND_DISPLAY",
                all(k in out for k in ("GREETD_SOCK=/run/palm-login.sock", "PALM_LOGIN=1", "XDG_RUNTIME_DIR=/run/user/900", "WAYLAND_DISPLAY=")), out)

        # A wrong password.
        m.type("nope\n")
        time.sleep(3.5)
        m.screen("wrong-password")
        out = m.run("cat /var/log/palm-login.log")
        m.check("a wrong password is refused", "authentication failed for \"palm\"" in out, out)

        # The right one.
        m.type("palm\n")
        session = False
        for _ in range(30):
            out = m.run("ps -o user,args | grep '[w]m --drm' || true")
            if re.search(r"^\s*palm\s+wm --drm\s*$", out, re.M):
                session = True
                break
            time.sleep(1)
        m.check("the right password starts `wm --drm` as palm", session, m.run("ps -o user,args; tail -20 /var/log/palm-login.log"))
        time.sleep(4)
        w, h, rgb = m.screen("session")
        lit, colours = stats(w, h, rgb)
        print(f"  ....  session screen {w}x{h}, {lit:.0%} lit, {colours} colours")

        out = m.run("tr '\\0' '\\n' < /proc/$(pidof wm)/environ | sort")
        for k in ("HOME=/home/palm", "USER=palm", "LOGNAME=palm", "SHELL=", "PATH=", "XDG_RUNTIME_DIR=/run/user/1000",
                  "XDG_SESSION_TYPE=wayland", "XDG_CURRENT_DESKTOP=palmframe"):
            m.check(f"session env has {k}", k in out, out)
        out = m.run("ls -ldn /run/user/1000; grep -E '^(Uid|Gid|Groups)' /proc/$(pidof wm)/status")
        m.check("/run/user/1000 is 0700 1000:1000", re.search(r"drwx------\s+\d+\s+1000\s+1000", out) is not None, out)
        m.check("the session has palm's groups", re.search(r"Groups:\s+.*\b10\b.*\b39\b", out) is not None or
                re.search(r"Groups:.*39.*", out) is not None, out)
        out = m.run("ls -ln /var/log/; tail -5 /var/log/session-palm.log")
        m.check("the session log is palm's", re.search(r"-rw-------\s+\d+\s+1000\s+1000 .*session-palm.log", out) is not None, out)

        # Log out (end the session from the console), and the greeter is back.
        m.run("kill $(pidof wm)")
        back = False
        for _ in range(30):
            out = m.run("ps -o user,comm | grep '[g]reeter' || true")
            if re.search(r"greeter\s+greeter", out):
                back = True
                break
            time.sleep(1)
        m.check("logging out returns to the greeter", back, m.run("tail -8 /var/log/palm-login.log"))
        time.sleep(3)
        m.screen("greeter-again")

        # Restart, from the keyboard: Tab from the password to the session
        # selector, Tab again to Restart (Suspend is not offered), Enter. The
        # greeter asks palm-login, palm-login runs /sbin/reboot, palm-init
        # reboots, and QEMU (-no-reboot) exits.
        m.key("tab")
        m.key("tab")
        time.sleep(0.5)
        m.screen("restart-focused")
        m.key("ret")
        m.check("palm-login ran /sbin/reboot for the greeter", m.expect(r"palm-init: rebooting", 20) is not None)
        try:
            m.proc.wait(30)
            exited = True
        except subprocess.TimeoutExpired:
            exited = False
        m.check("the machine restarts (QEMU exits under -no-reboot)", exited)
    finally:
        m.close()
    return m.failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--initrd", required=True)
    ap.add_argument("--work", required=True)
    args = ap.parse_args()
    failures = login(args)
    print(f"test-boot: {'all passed' if not failures else f'{len(failures)} failed'}; screenshots in {args.work}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
