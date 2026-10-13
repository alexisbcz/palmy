#!/usr/bin/env python3
"""A deliberately poor Wayland compositor, for testing palmy clients.

Palmframe's window manager offers a rich set of globals; a minimal or broken
system may offer far fewer. This stub advertises only what the core protocol
and xdg-shell make mandatory -- wl_compositor, wl_shm (XRGB8888 and ARGB8888,
nothing else), xdg_wm_base and a wl_seat -- and none of the extras palmy uses
when they are present: no cursor-shape-v1, no xdg-decoration, no layer-shell,
no wl_output, no fractional scale. A client that comes up and draws here is a
client that does not depend on any of them. --layer-shell adds
zwlr_layer_shell_v1 back, for the clients (launcher, greeter) that are layer
surfaces by design and that the real window manager serves.

It writes the last frame the client committed to a PNG, and can type into the
window: the keyboard keymap is either a real XKB keymap (--keymap FILE) or the
protocol's `no_keymap` format, which forces palmy onto its built-in US layout
-- the path a system without libxkbcommon takes.

    stubwl.py --socket $XDG_RUNTIME_DIR/wayland-stub --png out.png \\
              --seconds 6 --type '12+30=' --type-after 2

Only the standard library: it runs on the build host as-is.
"""

import argparse
import array
import os
import socket
import struct
import sys
import time
import zlib
import mmap
import select

# evdev key codes for the characters --type understands, with whether shift is
# held. The US layout, which is what both the fallback and a default keymap use.
_ROW = {
    "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9, "9": 10, "0": 11,
    "-": 12, "=": 13, "q": 16, "w": 17, "e": 18, "r": 19, "t": 20, "y": 21, "u": 22,
    "i": 23, "o": 24, "p": 25, "a": 30, "s": 31, "d": 32, "f": 33, "g": 34, "h": 35,
    "j": 36, "k": 37, "l": 38, "z": 44, "x": 45, "c": 46, "v": 47, "b": 48, "n": 49,
    "m": 50, " ": 57, ".": 52, "/": 53, ",": 51, "\n": 28,
}
_SHIFTED = {"+": "=", "*": "8", "(": "9", ")": "0", "!": "1", "?": "/"}
KEY_LEFTSHIFT = 42


def keys_for(text):
    out = []
    for ch in text:
        if ch in _ROW:
            out.append((_ROW[ch], False))
        elif ch in _SHIFTED:
            out.append((_ROW[_SHIFTED[ch]], True))
        elif ch.lower() in _ROW:
            out.append((_ROW[ch.lower()], True))
        else:
            raise SystemExit(f"stubwl: cannot type {ch!r}")
    return out


def pad(n):
    return (n + 3) & ~3


def write_png(path, width, height, rows_bgrx):
    raw = bytearray()
    for row in rows_bgrx:
        raw.append(0)
        # BGRX little endian -> RGB.
        rgb = bytearray(len(row) // 4 * 3)
        rgb[0::3] = row[2::4]
        rgb[1::3] = row[1::4]
        rgb[2::3] = row[0::4]
        raw += rgb

    def chunk(kind, data):
        c = struct.pack(">I", len(data)) + kind + data
        return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


class Client:
    def __init__(self, sock, args):
        self.sock = sock
        self.args = args
        self.objects = {1: "wl_display"}
        self.data = {}  # per-object state
        self.fds = []
        self.buf = b""
        self.serial = 100
        self.frame_cbs = []
        self.surface = None
        self.toplevel_surface = None
        self.keyboard = None
        self.pointer = None
        self.mapped_at = None
        self.frames = 0
        self.last = None  # (w, h, rows)
        self.log = []
        self.errors = []

    # -- sending --------------------------------------------------------------

    def send(self, obj, opcode, payload=b"", fds=()):
        msg = struct.pack("<II", obj, ((8 + len(payload)) << 16) | opcode) + payload
        if fds:
            self.sock.sendmsg([msg], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds))])
        else:
            self.sock.sendall(msg)

    @staticmethod
    def s(text):
        b = text.encode() + b"\0"
        return struct.pack("<I", len(b)) + b + b"\0" * (pad(len(b)) - len(b))

    @staticmethod
    def arr(b):
        return struct.pack("<I", len(b)) + b + b"\0" * (pad(len(b)) - len(b))

    def next_serial(self):
        self.serial += 1
        return self.serial

    # -- receiving ------------------------------------------------------------

    def pump(self, timeout):
        r, _, _ = select.select([self.sock], [], [], timeout)
        if not r:
            return True
        data, anc, _, _ = self.sock.recvmsg(65536, socket.CMSG_SPACE(28 * 4))
        if not data:
            return False
        for level, kind, cdata in anc:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                a = array.array("i")
                a.frombytes(cdata[: len(cdata) - (len(cdata) % 4)])
                self.fds.extend(a)
        self.buf += data
        while len(self.buf) >= 8:
            obj, word = struct.unpack_from("<II", self.buf)
            size, opcode = word >> 16, word & 0xFFFF
            if len(self.buf) < size:
                break
            body = self.buf[8:size]
            self.buf = self.buf[size:]
            self.dispatch(obj, opcode, body)
        return True

    def dispatch(self, obj, op, body):
        iface = self.objects.get(obj)
        u = lambda i: struct.unpack_from("<I", body, i)[0]
        n = lambda i: struct.unpack_from("<i", body, i)[0]

        def string(i):
            ln = u(i)
            return body[i + 4 : i + 4 + ln - 1].decode(), i + 4 + pad(ln)

        if iface == "wl_display":
            if op == 0:  # sync
                cb = u(0)
                self.send(cb, 0, struct.pack("<I", self.next_serial()))
                self.send(1, 1, struct.pack("<I", cb))
            elif op == 1:  # get_registry
                reg = u(0)
                self.objects[reg] = "wl_registry"
                for name, (gi, ver) in enumerate(GLOBALS, 1):
                    self.send(reg, 0, struct.pack("<I", name) + self.s(gi) + struct.pack("<I", ver))
        elif iface == "wl_registry" and op == 0:
            name = u(0)
            gi, i = string(4)
            ver, nid = u(i), u(i + 4)
            self.objects[nid] = gi
            self.log.append(f"bind {gi} v{ver}")
            if gi == "wl_shm":
                self.send(nid, 0, struct.pack("<I", 0))
                self.send(nid, 0, struct.pack("<I", 1))
            elif gi == "wl_seat":
                self.send(nid, 0, struct.pack("<I", 3))  # pointer | keyboard
                if ver >= 2:
                    self.send(nid, 1, self.s("seat0"))
        elif iface == "wl_compositor":
            if op == 0:
                self.objects[u(0)] = "wl_surface"
                self.data[u(0)] = {"buffer": None, "frames": []}
            elif op == 1:
                self.objects[u(0)] = "wl_region"
        elif iface == "wl_shm" and op == 0:
            pool, size = u(0), n(4)
            fd = self.fds.pop(0)
            self.objects[pool] = "wl_shm_pool"
            self.data[pool] = {"fd": fd, "size": size}
        elif iface == "wl_shm_pool":
            if op == 0:
                bid, off, w, h, stride, fmt = u(0), n(4), n(8), n(12), n(16), u(20)
                self.objects[bid] = "wl_buffer"
                self.data[bid] = {"pool": obj, "off": off, "w": w, "h": h, "stride": stride, "fmt": fmt}
            elif op == 1:
                os.close(self.data[obj]["fd"])
            elif op == 2:
                self.data[obj]["size"] = n(0)
        elif iface == "wl_surface":
            st = self.data[obj]
            if op == 1:
                st["buffer"] = u(0) or None
            elif op == 3:
                self.objects[u(0)] = "wl_callback"
                st["frames"].append(u(0))
            elif op == 6:
                self.commit(obj)
        elif iface == "xdg_wm_base":
            if op == 2:
                xs, surf = u(0), u(4)
                self.objects[xs] = "xdg_surface"
                self.data[xs] = {"surface": surf}
            elif op == 1:
                self.objects[u(0)] = "xdg_positioner"
        elif iface == "xdg_surface":
            if op == 1:
                tl = u(0)
                self.objects[tl] = "xdg_toplevel"
                surf = self.data[obj]["surface"]
                self.data[surf]["xdg_surface"] = obj
                self.data[surf]["toplevel"] = tl
                self.toplevel_surface = surf
            elif op == 2:
                self.errors.append("client asked for an xdg_popup")
        elif iface == "xdg_toplevel":
            if op == 2:
                t, _ = string(0)
                self.log.append(f"title {t!r}")
            elif op == 3:
                t, _ = string(0)
                self.log.append(f"app_id {t!r}")
        elif iface == "zwlr_layer_shell_v1" and op == 0:
            ls, surf = u(0), u(4)
            self.objects[ls] = "zwlr_layer_surface_v1"
            self.data[ls] = {"surface": surf, "size": (0, 0)}
            self.data[surf]["layer_surface"] = ls
            self.toplevel_surface = surf
        elif iface == "zwlr_layer_surface_v1" and op == 0:
            self.data[obj]["size"] = (u(0), u(4))
        elif iface == "wl_seat":
            if op == 0:
                self.pointer = u(0)
                self.objects[self.pointer] = "wl_pointer"
            elif op == 1:
                self.keyboard = u(0)
                self.objects[self.keyboard] = "wl_keyboard"
                self.send_keymap()
        # Everything else (regions, positioners, set_title, ...) needs no reply.

    def send_keymap(self):
        if self.args.keymap:
            with open(self.args.keymap, "rb") as f:
                text = f.read() + b"\0"
            fd = os.memfd_create("keymap")
            os.write(fd, text)
            self.send(self.keyboard, 0, struct.pack("<II", 1, len(text)), [fd])
            os.close(fd)
            self.log.append("keymap: xkb_v1")
        else:
            # format 0 is `no_keymap`; the fd is still required on the wire.
            fd = os.open("/dev/null", os.O_RDONLY)
            self.send(self.keyboard, 0, struct.pack("<II", 0, 0), [fd])
            os.close(fd)
            self.log.append("keymap: no_keymap")

    def commit(self, surf):
        st = self.data[surf]
        xs = st.get("xdg_surface")
        if xs is not None and not st.get("configured"):
            st["configured"] = True
            w, h = self.args.size
            self.send(st["toplevel"], 0, struct.pack("<ii", w, h) + self.arr(struct.pack("<I", 4)))
            self.send(xs, 0, struct.pack("<I", self.next_serial()))
        ls = st.get("layer_surface")
        if ls is not None and not st.get("configured"):
            st["configured"] = True
            w, h = self.data[ls]["size"]
            if w == 0 or h == 0:
                w, h = self.args.size
            self.send(ls, 0, struct.pack("<III", self.next_serial(), w, h))
        bid = st["buffer"]
        if bid is not None:
            b = self.data[bid]
            pool = self.data[b["pool"]]
            m = mmap.mmap(pool["fd"], pool["size"], prot=mmap.PROT_READ)
            rows = [m[b["off"] + y * b["stride"] : b["off"] + y * b["stride"] + b["w"] * 4] for y in range(b["h"])]
            m.close()
            self.last = (b["w"], b["h"], rows)
            self.frames += 1
            if self.mapped_at is None:
                self.mapped_at = time.monotonic()
            self.send(bid, 0)  # release
            st["buffer"] = None
        for cb in st["frames"]:
            self.send(cb, 0, struct.pack("<I", int(time.monotonic() * 1000) & 0xFFFFFFFF))
            self.send(1, 1, struct.pack("<I", cb))
        st["frames"] = []

    def focus(self):
        if self.keyboard and self.toplevel_surface:
            self.send(self.keyboard, 1, struct.pack("<II", self.next_serial(), self.toplevel_surface) + self.arr(b""))
            self.send(self.keyboard, 4, struct.pack("<IIIII", self.next_serial(), 0, 0, 0, 0))
        if self.pointer and self.toplevel_surface:
            w, h = self.args.size
            self.send(self.pointer, 0, struct.pack("<IIii", self.next_serial(), self.toplevel_surface, (w // 2) << 8, (h // 2) << 8))

    def key(self, code, down):
        t = int(time.monotonic() * 1000) & 0xFFFFFFFF
        self.send(self.keyboard, 3, struct.pack("<IIII", self.next_serial(), t, code, 1 if down else 0))

    def mods(self, shift):
        self.send(self.keyboard, 4, struct.pack("<IIIII", self.next_serial(), 1 if shift else 0, 0, 0, 0))


GLOBALS = [
    ("wl_compositor", 4),
    ("wl_shm", 1),
    ("xdg_wm_base", 2),
    ("wl_seat", 5),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--png", required=True)
    ap.add_argument("--seconds", type=float, default=5)
    ap.add_argument("--size", type=lambda s: tuple(int(x) for x in s.split("x")), default=(900, 600))
    ap.add_argument("--keymap", help="XKB keymap text to send; default is no_keymap")
    ap.add_argument("--type", default="", help="text to type once the window is up")
    ap.add_argument("--type-after", type=float, default=1.5)
    ap.add_argument("--layer-shell", action="store_true",
                    help="also offer zwlr_layer_shell_v1, for the launcher and greeter")
    args = ap.parse_args()
    if args.layer_shell:
        GLOBALS.append(("zwlr_layer_shell_v1", 4))

    try:
        os.unlink(args.socket)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(args.socket)
    srv.listen(1)
    print(f"stubwl: listening on {args.socket}", flush=True)
    r, _, _ = select.select([srv], [], [], args.seconds + 10)
    if not r:
        print("stubwl: no client connected", flush=True)
        sys.exit(2)
    conn, _ = srv.accept()
    c = Client(conn, args)
    start = time.monotonic()
    try:
        alive = run(c, args, start)
    except (BrokenPipeError, ConnectionResetError):
        # The client died mid-conversation. Still report, and still keep the
        # last frame it managed to show: that is the evidence.
        alive = False
    report(c, args, alive)


def run(c, args, start):
    typed = False
    alive = True
    while time.monotonic() - start < args.seconds and alive:
        alive = c.pump(0.02)
        if c.mapped_at is not None and not typed and time.monotonic() - c.mapped_at > args.type_after:
            typed = True
            c.focus()
            for code, shift in keys_for(args.type):
                if shift:
                    c.key(KEY_LEFTSHIFT, True)
                    c.mods(True)
                c.key(code, True)
                c.key(code, False)
                if shift:
                    c.key(KEY_LEFTSHIFT, False)
                    c.mods(False)
                # One key per frame or so: palmy collapses repeats within a frame.
                end = time.monotonic() + 0.06
                while time.monotonic() < end and alive:
                    alive = c.pump(0.01)
    return alive


def report(c, args, alive):
    for line in c.log:
        print("stubwl:", line)
    for e in c.errors:
        print("stubwl: ERROR", e)
    print(f"stubwl: {c.frames} frames committed, client {'alive' if alive else 'disconnected'}", flush=True)
    if c.last:
        w, h, rows = c.last
        write_png(args.png, w, h, rows)
        print(f"stubwl: wrote {w}x{h} frame to {args.png}")
        sys.exit(0)
    sys.exit(1)


if __name__ == "__main__":
    main()
