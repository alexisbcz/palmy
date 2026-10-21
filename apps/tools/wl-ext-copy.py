#!/usr/bin/env python3
"""Own the Wayland clipboard through ext_data_control_v1, from a file.

    wl-ext-copy.py <file> [seconds]
    wl-ext-copy.py --globals          list the compositor's globals and exit

Speaks the protocol directly (no libwayland, no bindings): creates a data
control source offering the file's bytes as text, sets it as the selection
through a data control device -- which needs no focus and no input serial, the
point of the protocol -- and serves every `send` until it is cancelled or the
time is up. Prints "OWNED", then "SERVED <mime>" per request. For checking a
client's ext_data_control_v1 support against a compositor that implements it
(wlroots 0.19 and later), where wl-copy may only speak the older zwlr one.
"""
import array
import os
import socket
import struct
import sys
import time

TYPES = ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "TEXT", "STRING"]


def main():
    list_only = sys.argv[1] == "--globals"
    data = b"" if list_only else open(sys.argv[1], "rb").read()
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 10
    name = os.environ.get("WAYLAND_DISPLAY", "wayland-0")
    path = name if name.startswith("/") else os.path.join(os.environ["XDG_RUNTIME_DIR"], name)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    nid = [2]

    def new():
        i = nid[0]
        nid[0] += 1
        return i

    def send(obj, op, fmt="", *args):
        body = b""
        for f, a in zip(fmt, args):
            if f in "uon":
                body += struct.pack("<I", a)
            elif f == "s":
                b = a.encode() + b"\0"
                body += struct.pack("<I", len(b)) + b + b"\0" * ((4 - len(b) % 4) % 4)
        s.sendall(struct.pack("<II", obj, op | ((8 + len(body)) << 16)) + body)

    buf = b""
    fds = []
    globals_ = {}
    handlers = {}

    def pump(timeout=None):
        nonlocal buf
        s.settimeout(timeout)
        try:
            msg, anc, _, _ = s.recvmsg(65536, socket.CMSG_SPACE(16 * 4))
        except socket.timeout:
            return
        if not msg:
            raise SystemExit("wl-ext-copy: the compositor closed the connection")
        for level, kind, payload in anc:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                a = array.array("i")
                a.frombytes(payload[: len(payload) - len(payload) % 4])
                fds.extend(a)
        buf += msg
        while len(buf) >= 8:
            obj, hdr = struct.unpack_from("<II", buf)
            size = hdr >> 16
            if len(buf) < size:
                break
            p, buf = buf[8:size], buf[size:]
            h = handlers.get(obj)
            if h:
                h(hdr & 0xFFFF, p)

    def roundtrip():
        cb = new()
        done = []
        handlers[cb] = lambda op, p: done.append(1)
        send(1, 0, "n", cb)
        while not done:
            pump()

    def on_display(op, p):
        if op == 0:
            obj, code, n = struct.unpack_from("<III", p)
            raise SystemExit("wl-ext-copy: protocol error %d on %d: %s" % (code, obj, p[12:12 + n - 1].decode()))

    handlers[1] = on_display
    reg = new()

    def on_global(op, p):
        if op == 0:
            name_, n = struct.unpack_from("<II", p)
            iface = p[8:8 + n - 1].decode()
            ver = struct.unpack_from("<I", p, 8 + ((n + 3) & ~3))[0]
            globals_.setdefault(iface, (name_, ver))

    handlers[reg] = on_global
    send(1, 1, "n", reg)
    roundtrip()
    if list_only:
        for iface, (_, ver) in sorted(globals_.items()):
            print("%s %d" % (iface, ver))
        return
    if "ext_data_control_manager_v1" not in globals_:
        print("NO_EXT_DATA_CONTROL", flush=True)
        sys.exit(3)

    def bind(iface, ver):
        name_, have = globals_[iface]
        i = new()
        send(reg, 0, "usun", name_, iface, min(ver, have), i)
        return i

    seat = bind("wl_seat", 1)
    mgr = bind("ext_data_control_manager_v1", 1)
    src = new()
    send(mgr, 0, "n", src)  # create_data_source
    for t in TYPES:
        send(src, 0, "s", t)  # offer
    dev = new()
    send(mgr, 1, "no", dev, seat)  # get_data_device
    cancelled = []

    def on_source(op, p):
        if op == 0:  # send(mime, fd)
            n = struct.unpack_from("<I", p)[0]
            mime = p[4:4 + n - 1].decode()
            fd = fds.pop(0)
            try:
                os.set_blocking(fd, True)
                view = memoryview(data)
                while view:
                    w = os.write(fd, view)
                    view = view[w:]
            except OSError:
                pass
            os.close(fd)
            print("SERVED " + mime, flush=True)
        elif op == 1:  # cancelled
            cancelled.append(1)

    handlers[src] = on_source
    send(dev, 0, "o", src)  # set_selection
    roundtrip()
    print("OWNED %d" % len(data), flush=True)
    end = time.monotonic() + secs
    while not cancelled and time.monotonic() < end:
        pump(0.2)
    print("CANCELLED" if cancelled else "TIMEOUT", flush=True)


if __name__ == "__main__":
    main()
