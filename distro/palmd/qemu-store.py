"""Drive a headless Palmframe VM one step at a time, for testing Software and palmd.

    python3 -I distro/palmd/qemu-store.py boot           copy the image, start QEMU (OVMF), log root in on serial
    python3 -I distro/palmd/qemu-store.py serve [PORT]   `make -C distro serve PORT=...` in the background (8091)
    python3 -I distro/palmd/qemu-store.py sh 'CMD'       run CMD in the serial root shell; prints output, exits with its status
    python3 -I distro/palmd/qemu-store.py type 'TEXT'    type into whatever has the keyboard
    python3 -I distro/palmd/qemu-store.py key meta_l s   press a chord (QMP qcodes)
    python3 -I distro/palmd/qemu-store.py click X Y      move the tablet to output pixel X,Y and click
    python3 -I distro/palmd/qemu-store.py shot FILE.png  QMP screendump
    python3 -I distro/palmd/qemu-store.py stop           kill QEMU and the server

Unlike distro/image/test-boot.py, which runs a fixed script in one process,
each step here is its own process: the VM and the repository server outlive
them, so a person (or an agent) can look at a screenshot before deciding
where to click next. State lives in distro/build/store-qemu/; every socket,
image and pid file there is prefixed store- so it cannot collide with another
VM run from the same checkout. The image is a sparse copy, so the shipped
distro/out/palmframe.img is never written.

The serial console is a QEMU socket chardev that accepts one client at a
time; each step connects, does its work and leaves, and the root shell it
logged into stays logged in between steps.
"""

import json
import os
import re
import signal
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DISTRO = os.path.dirname(HERE)
WORK = os.path.join(DISTRO, "build", "store-qemu")
SERIAL = os.path.join(WORK, "store-serial.sock")
QMP = os.path.join(WORK, "store-qmp.sock")
IMG = os.path.join(WORK, "store-test.img")
QEMU_PID = os.path.join(WORK, "store-qemu.pid")
SERVE_PID = os.path.join(WORK, "store-serve.pid")
TRANSCRIPT = os.path.join(WORK, "store-serial.txt")


def connect(path, timeout=15):
    deadline = time.time() + timeout
    while True:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(path)
            return s
        except OSError:
            if time.time() > deadline:
                raise
            time.sleep(0.05)


class Serial:
    def __init__(self):
        self.s = connect(SERIAL)
        self.s.setblocking(False)
        self.buf = ""
        self.mark = 0
        self.log = open(TRANSCRIPT, "a")

    def pump(self, wait):
        end = time.time() + wait
        while True:
            try:
                data = self.s.recv(65536)
                if not data:
                    return
                t = data.decode("utf-8", "replace").replace("\r", "").replace("\0", "")
                self.buf += t
                self.log.write(t)
                self.log.flush()
            except BlockingIOError:
                if time.time() >= end:
                    return
                time.sleep(0.02)

    def expect(self, pattern, timeout=30, flags=re.M):
        rx = re.compile(pattern, flags)
        deadline = time.time() + timeout
        while True:
            m = rx.search(self.buf, self.mark)
            if m:
                self.mark = m.end()
                return m
            if time.time() > deadline:
                return None
            self.pump(0.1)

    def send(self, line):
        self.s.sendall((line + "\r").encode())

    def shell(self):
        """Make sure a root shell is at the prompt, logging in if needed."""
        self.mark = len(self.buf)
        self.send("")
        m = self.expect(r"(login: $|# $|Password: $)", 10)
        if m and m.group(1).startswith("login"):
            self.send("root")
            self.expect(r"Password: ", 10)
            self.send("palm")
            if not self.expect(r"# $", 15):
                raise RuntimeError("root login on the serial console failed")
            self.run("stty -echo cols 250")
        elif m and m.group(1).startswith("Password"):
            self.send("palm")
            self.expect(r"# $", 15)

    def run(self, command, timeout=60):
        tag = f"@@{int(time.time() * 1000) % 1000000}@@"
        self.send(f"echo {tag}B; {command}; echo {tag}E$?")
        m = self.expect(re.escape(tag) + r"B\n(.*?)" + re.escape(tag) + r"E(\d+)\n", timeout, re.S)
        return (m.group(1), int(m.group(2))) if m else ("(timed out)\n" + self.buf[-2000:], 124)


def qmp(*commands):
    s = connect(QMP)
    f = s.makefile("rw")
    json.loads(f.readline())
    out = []
    for cmd in [{"execute": "qmp_capabilities"}] + list(commands):
        f.write(json.dumps(cmd) + "\n")
        f.flush()
        while True:
            r = json.loads(f.readline())
            if "event" in r:
                continue
            out.append(r)
            break
    s.close()
    return out[1:]


def key_ev(q, down):
    return {"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": q}}}


def press(*qcodes):
    qmp({"execute": "input-send-event", "arguments": {"events": [key_ev(q, True) for q in qcodes]}})
    time.sleep(0.04)
    qmp({"execute": "input-send-event", "arguments": {"events": [key_ev(q, False) for q in reversed(qcodes)]}})
    time.sleep(0.05)


NAMES = {" ": "spc", "\n": "ret", "-": "minus", ".": "dot", "/": "slash", "=": "equal",
         ";": "semicolon", ",": "comma", "'": "apostrophe"}
SHIFTED = {"|": "backslash", "&": "7", ":": "semicolon", "_": "minus", ">": "dot", "$": "4",
           '"': "apostrophe", "+": "equal", "(": "9", ")": "0"}


def type_text(text):
    for ch in text:
        if ch.isupper():
            press("shift", ch.lower())
        elif ch in SHIFTED:
            press("shift", SHIFTED[ch])
        else:
            press(NAMES.get(ch, ch))


def screen_size():
    ppm = os.path.join(WORK, "store-size.ppm")
    qmp({"execute": "screendump", "arguments": {"filename": ppm}})
    with open(ppm, "rb") as f:
        parts = f.read(64).split(b"\n")
    os.unlink(ppm)
    w, h = map(int, parts[1].split())
    return w, h


def click(x, y, button="left"):
    w, h = screen_size()
    ax, ay = int(x * 0x7FFF / (w - 1)), int(y * 0x7FFF / (h - 1))
    move = [{"type": "abs", "data": {"axis": "x", "value": ax}}, {"type": "abs", "data": {"axis": "y", "value": ay}}]
    btn = lambda d: {"type": "btn", "data": {"down": d, "button": button}}
    qmp({"execute": "input-send-event", "arguments": {"events": move}})
    time.sleep(0.08)
    qmp({"execute": "input-send-event", "arguments": {"events": [btn(True)]}})
    time.sleep(0.06)
    qmp({"execute": "input-send-event", "arguments": {"events": [btn(False)]}})


def alive(pidfile):
    try:
        pid = int(open(pidfile).read())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return 0


def boot():
    os.makedirs(WORK, exist_ok=True)
    if alive(QEMU_PID):
        print("qemu-store: already running; `stop` first")
        return 1
    subprocess.run(["cp", "--sparse=always", os.path.join(DISTRO, "out", "palmframe.img"), IMG], check=True)
    for p in (SERIAL, QMP):
        if os.path.exists(p):
            os.unlink(p)
    open(TRANSCRIPT, "w").close()
    proc = subprocess.Popen(
        [os.path.join(DISTRO, "run-qemu.sh"), "--serial-socket", SERIAL, "--qmp-socket", QMP, "--", "-no-reboot"],
        env=dict(os.environ, IMG=IMG), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=open(os.path.join(WORK, "store-qemu.log"), "w"), start_new_session=True)
    open(QEMU_PID, "w").write(str(proc.pid))
    ser = Serial()
    if not ser.expect(r"palmframe login: ", 120):
        print("qemu-store: no login prompt on the serial console")
        return 1
    ser.shell()
    print("qemu-store: booted; root shell on the serial console")
    return 0


def serve(port):
    if alive(SERVE_PID):
        print("qemu-store: already serving")
        return 0
    proc = subprocess.Popen(["make", "-C", DISTRO, "serve", f"PORT={port}"], stdin=subprocess.DEVNULL,
                            stdout=open(os.path.join(WORK, "store-serve.log"), "w"), stderr=subprocess.STDOUT,
                            start_new_session=True)
    open(SERVE_PID, "w").write(str(proc.pid))
    print(f"qemu-store: serving distro/out/repo on :{port} (the guest: http://10.0.2.2:{port}/x86_64)")
    return 0


def stop():
    for pidfile in (QEMU_PID, SERVE_PID):
        pid = alive(pidfile)
        if pid:
            try:
                os.killpg(pid, signal.SIGTERM)
            except OSError:
                os.kill(pid, signal.SIGTERM)
        if os.path.exists(pidfile):
            os.unlink(pidfile)
    for p in (SERIAL, QMP):
        if os.path.exists(p):
            os.unlink(p)
    print("qemu-store: stopped")
    return 0


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    verb, rest = argv[0], argv[1:]
    if verb == "boot":
        return boot()
    if verb == "serve":
        return serve(int(rest[0]) if rest else 8091)
    if verb == "stop":
        return stop()
    if verb == "sh":
        ser = Serial()
        ser.shell()
        out, st = ser.run(" ".join(rest), timeout=float(os.environ.get("STORE_TIMEOUT", "120")))
        sys.stdout.write(out)
        return st
    if verb == "type":
        type_text(" ".join(rest))
        return 0
    if verb == "key":
        press(*rest)
        return 0
    if verb == "click":
        click(int(rest[0]), int(rest[1]), rest[2] if len(rest) > 2 else "left")
        return 0
    if verb == "shot":
        path = os.path.abspath(rest[0])
        qmp({"execute": "screendump", "arguments": {"filename": path, "format": "png"}})
        print(path)
        return 0
    print(f"qemu-store: unknown verb {verb}")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
