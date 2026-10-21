#!/usr/bin/env python3
"""A virtual pointer for a wlroots compositor, driven from stdin.

    wl-pointer.py [--width W --height H] < commands

Commands, one per line:
    move X Y        absolute position in the output's layout coordinates
    down [BUTTON]   press (left, right or middle; default left)
    up [BUTTON]     release
    click [BUTTON]  press and release
    wheel DY        vertical scroll, in wl_pointer axis units (10 per notch)
    sleep SECONDS
    # comment

It speaks zwlr_virtual_pointer_v1 directly over the Wayland socket (no
libwayland, no python bindings), creates ONE pointer for its whole life and
waits for the compositor to acknowledge every command with a wl_display.sync,
so a step has been delivered when the next one starts.

Why one pointer for the whole run matters: on a headless seat the pointer
capability exists only while a virtual pointer does. A tool that creates a
pointer per step (wlrctl) toggles the capability every time; the client is told
to drop its wl_pointer and bind a new one, and whatever the device did before
the client re-bound -- the enter, the press -- went to nobody.
"""
import os
import socket
import struct
import sys
import time

BTN = {"left": 0x110, "right": 0x111, "middle": 0x112}


class Conn:
    def __init__(self):
        name = os.environ.get("WAYLAND_DISPLAY", "wayland-0")
        path = name if name.startswith("/") else os.path.join(os.environ["XDG_RUNTIME_DIR"], name)
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.next_id = 2
        self.buf = b""
        self.globals = {}  # interface -> (name, version)
        self.handlers = {}  # object id -> callable(opcode, payload)

    def new_id(self):
        i = self.next_id
        self.next_id += 1
        return i

    def send(self, obj, op, fmt="", *args):
        body = b""
        for f, a in zip(fmt, args):
            if f in "uon":
                body += struct.pack("<I", a)
            elif f == "i":
                body += struct.pack("<i", a)
            elif f == "f":
                body += struct.pack("<i", int(round(a * 256)))
            elif f == "s":
                b = a.encode() + b"\0"
                body += struct.pack("<I", len(b)) + b + b"\0" * ((4 - len(b) % 4) % 4)
        self.s.sendall(struct.pack("<II", obj, op | ((8 + len(body)) << 16)) + body)

    def dispatch_once(self):
        data = self.s.recv(65536)
        if not data:
            raise SystemExit("wl-pointer: the compositor closed the connection")
        self.buf += data
        while len(self.buf) >= 8:
            obj, hdr = struct.unpack_from("<II", self.buf)
            size = hdr >> 16
            if len(self.buf) < size:
                break
            payload = self.buf[8:size]
            self.buf = self.buf[size:]
            h = self.handlers.get(obj)
            if h:
                h(hdr & 0xFFFF, payload)

    def roundtrip(self):
        cb = self.new_id()
        done = []
        self.handlers[cb] = lambda op, p: done.append(1)
        self.send(1, 0, "n", cb)  # wl_display.sync
        while not done:
            self.dispatch_once()
        del self.handlers[cb]


def main():
    c = Conn()

    def on_display(op, p):
        if op == 0:
            obj, code = struct.unpack_from("<II", p)
            n = struct.unpack_from("<I", p, 8)[0]
            raise SystemExit("wl-pointer: protocol error %d on %d: %s" % (code, obj, p[12:12 + n - 1].decode()))

    c.handlers[1] = on_display
    reg = c.new_id()

    def on_registry(op, p):
        if op == 0:
            name, n = struct.unpack_from("<II", p)
            iface = p[8:8 + n - 1].decode()
            off = 8 + ((n + 3) & ~3)
            ver = struct.unpack_from("<I", p, off)[0]
            c.globals.setdefault(iface, (name, ver))

    c.handlers[reg] = on_registry
    c.send(1, 1, "n", reg)  # get_registry
    c.roundtrip()

    if "zwlr_virtual_pointer_manager_v1" not in c.globals:
        raise SystemExit("wl-pointer: the compositor has no zwlr_virtual_pointer_manager_v1")

    def bind(iface, ver):
        name, have = c.globals[iface]
        i = c.new_id()
        c.send(reg, 0, "usun", name, iface, min(ver, have), i)
        return i

    seat = bind("wl_seat", 1)
    mgr = bind("zwlr_virtual_pointer_manager_v1", 1)
    ptr = c.new_id()
    c.send(mgr, 0, "on", seat, ptr)  # create_virtual_pointer
    c.roundtrip()

    w = int(os.environ.get("WL_POINTER_WIDTH", "0"))
    h = int(os.environ.get("WL_POINTER_HEIGHT", "0"))
    args = sys.argv[1:]
    while args:
        a = args.pop(0)
        if a == "--width":
            w = int(args.pop(0))
        elif a == "--height":
            h = int(args.pop(0))
    if w <= 0 or h <= 0:
        raise SystemExit("wl-pointer: give the output size with --width and --height")

    t0 = time.monotonic()

    def ms():
        return int((time.monotonic() - t0) * 1000) & 0xFFFFFFFF

    print("wl-pointer: ready", flush=True)
    for line in sys.stdin:
        words = line.split()
        if not words or words[0].startswith("#"):
            continue
        cmd = words[0]
        if cmd == "move":
            x, y = float(words[1]), float(words[2])
            # motion_absolute takes a position out of an extent; give the
            # output's own size as the extent so the numbers are pixels.
            c.send(ptr, 1, "uuuuu", ms(), int(round(x)), int(round(y)), w, h)
            c.send(ptr, 4, "")  # frame
        elif cmd in ("down", "up", "click"):
            b = BTN[words[1] if len(words) > 1 else "left"]
            if cmd in ("down", "click"):
                c.send(ptr, 2, "uuu", ms(), b, 1)
                c.send(ptr, 4, "")
            if cmd == "click":
                c.roundtrip()
                time.sleep(0.03)
            if cmd in ("up", "click"):
                c.send(ptr, 2, "uuu", ms(), b, 0)
                c.send(ptr, 4, "")
        elif cmd == "wheel":
            c.send(ptr, 3, "uuf", ms(), 0, float(words[1]))
            c.send(ptr, 4, "")
        elif cmd == "sleep":
            c.roundtrip()
            time.sleep(float(words[1]))
            continue
        else:
            print("wl-pointer: unknown command: " + line.strip(), file=sys.stderr, flush=True)
            continue
        c.roundtrip()
        print("wl-pointer: done " + line.strip(), flush=True)


if __name__ == "__main__":
    main()
