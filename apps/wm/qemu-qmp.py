#!/usr/bin/env python3
# qemu-qmp.py — drive a headless QEMU over QMP for the window manager's
# bare-metal test (apps/wm/qemu-test.sh).
#
# A script is a list of steps, one per argument:
#
#   wait:<seconds>            sleep
#   shot:<file.png>           QMP screendump, PNG
#   type:<text>               type ASCII text on the virtio keyboard
#   key:<qcode>[+<qcode>...]  press a chord, release in reverse (key:meta_l+ret)
#   move:<x>,<y>              absolute pointer to output pixel x,y (virtio-tablet)
#   click[:left|right|middle] press and release a button where the pointer is
#   down:<btn> / up:<btn>     press, or release, a button and leave it there,
#                             so a drag can be held across moves and shots
#   drag:x1,y1,x2,y2          move to x1,y1, press left, then twenty
#                             interpolated moves to x2,y2; no release
#   dbl                       two left press/release pairs 60 ms apart
#   wheel:up|down             one scroll detent where the pointer is
#   hold:<qcode> / release:<qcode>
#                             press, or release, a key and leave it there
#                             (hold:alt key:tab key:tab release:alt)
#   until:<s>:<file>:<text>   wait up to <s> seconds until <file> contains <text>
#   burst:<n>:<ms>:<prefix>   n screendumps <ms> apart, <prefix>-NN.png
#   qmp:<command>[:<json>]    any QMP command, e.g.
#                             qmp:device_add:{"driver":"usb-kbd","id":"k2"}
#   dev:<id>                  send the following input events to the device
#                             with this QOM id (dev: alone: QEMU's choice)
#
# The absolute axis is 0..0x7fff across the output whatever its mode, so a
# pixel position needs the output size: --size WxH (default 1280x800).
#
# Nothing here knows about the guest beyond QMP; it is a test harness, not
# part of the compositor.
import json
import socket
import sys
import time


class Qmp:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        for _ in range(100):
            try:
                self.s.connect(path)
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise SystemExit(f"qmp: cannot connect to {path}")
        self.f = self.s.makefile("rwb")
        self.read()  # greeting
        self.cmd("qmp_capabilities")

    def read(self):
        while True:
            line = self.f.readline()
            if not line:
                raise SystemExit("qmp: connection closed")
            msg = json.loads(line)
            if "event" in msg:
                continue
            return msg

    def cmd(self, name, **args):
        req = {"execute": name}
        if args:
            req["arguments"] = args
        self.f.write(json.dumps(req).encode() + b"\n")
        self.f.flush()
        r = self.read()
        if "error" in r:
            print(f"qmp: {name}: {r['error']}", file=sys.stderr)
        return r

    device = ""

    def events(self, evs):
        if self.device:
            return self.cmd("input-send-event", device=self.device, events=evs)
        return self.cmd("input-send-event", events=evs)


# ASCII to (qcode, shift). Enough for shell commands.
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal", "{": "bracket_left",
    "}": "bracket_right", "|": "backslash", ":": "semicolon", '"': "apostrophe",
    "<": "comma", ">": "dot", "?": "slash", "~": "grave_accent",
}
PLAIN = {
    " ": "spc", "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right",
    "\\": "backslash", ";": "semicolon", "'": "apostrophe", ",": "comma", ".": "dot",
    "/": "slash", "`": "grave_accent", "\n": "ret", "\t": "tab",
}


def qcode_for(ch):
    if ch.isalpha():
        return ch.lower(), ch.isupper()
    if ch.isdigit():
        return ch, False
    if ch in PLAIN:
        return PLAIN[ch], False
    if ch in SHIFTED:
        return SHIFTED[ch], True
    raise SystemExit(f"type: no qcode for {ch!r}")


def key_ev(code, down):
    return {"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": code}}}


def abs_ev(size, x, y):
    ax = x * 0x7FFF // max(size[0] - 1, 1)
    ay = y * 0x7FFF // max(size[1] - 1, 1)
    return [
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
    ]


def main():
    args = sys.argv[1:]
    size = (1280, 800)
    if args and args[0] == "--size":
        w, h = args[1].split("x")
        size = (int(w), int(h))
        args = args[2:]
    q = Qmp(args[0])
    for step in args[1:]:
        kind, _, rest = step.partition(":")
        if kind == "wait":
            time.sleep(float(rest))
        elif kind == "shot":
            q.cmd("screendump", filename=rest, format="png")
            print(f"shot {rest}", flush=True)
        elif kind == "type":
            for ch in rest.replace("\\n", "\n"):
                code, shift = qcode_for(ch)
                evs = []
                if shift:
                    evs.append(key_ev("shift", True))
                evs += [key_ev(code, True)]
                q.events(evs)
                time.sleep(0.03)
                evs = [key_ev(code, False)]
                if shift:
                    evs.append(key_ev("shift", False))
                q.events(evs)
                time.sleep(0.03)
        elif kind == "key":
            codes = rest.split("+")
            for c in codes:
                q.events([key_ev(c, True)])
                time.sleep(0.03)
            for c in reversed(codes):
                q.events([key_ev(c, False)])
                time.sleep(0.03)
        elif kind == "move":
            x, y = (int(v) for v in rest.split(","))
            q.events(abs_ev(size, x, y))
            time.sleep(0.05)
        elif kind == "click":
            btn = rest or "left"
            q.events([{"type": "btn", "data": {"down": True, "button": btn}}])
            time.sleep(0.08)
            q.events([{"type": "btn", "data": {"down": False, "button": btn}}])
            time.sleep(0.05)
        elif kind in ("down", "up"):
            btn = rest or "left"
            q.events([{"type": "btn", "data": {"down": kind == "down", "button": btn}}])
            time.sleep(0.05)
        elif kind == "drag":
            x1, y1, x2, y2 = (int(v) for v in rest.split(","))
            q.events(abs_ev(size, x1, y1))
            time.sleep(0.05)
            q.events([{"type": "btn", "data": {"down": True, "button": "left"}}])
            time.sleep(0.05)
            for i in range(1, 21):
                x = x1 + (x2 - x1) * i // 20
                y = y1 + (y2 - y1) * i // 20
                q.events(abs_ev(size, x, y))
                time.sleep(0.02)
            time.sleep(0.05)
        elif kind == "dbl":
            for _ in range(2):
                q.events([{"type": "btn", "data": {"down": True, "button": "left"}}])
                time.sleep(0.03)
                q.events([{"type": "btn", "data": {"down": False, "button": "left"}}])
                time.sleep(0.06)
        elif kind == "wheel":
            btn = "wheel-up" if rest == "up" else "wheel-down"
            q.events([{"type": "btn", "data": {"down": True, "button": btn}}])
            q.events([{"type": "btn", "data": {"down": False, "button": btn}}])
            time.sleep(0.05)
        elif kind in ("hold", "release"):
            q.events([key_ev(rest, kind == "hold")])
            time.sleep(0.03)
        elif kind == "burst":
            n_s, ms_s, prefix = rest.split(":", 2)
            for i in range(int(n_s)):
                t0 = time.time()
                q.cmd("screendump", filename=f"{prefix}-{i:02d}.png", format="png")
                left = int(ms_s) / 1000 - (time.time() - t0)
                if left > 0:
                    time.sleep(left)
            print(f"burst {prefix} x{n_s}", flush=True)
        elif kind == "qmp":
            name, _, js = rest.partition(":")
            r = q.cmd(name, **(json.loads(js) if js else {}))
            print(f"qmp {name}: {json.dumps(r)[:200]}", flush=True)
        elif kind == "dev":
            q.device = rest
        elif kind == "until":
            limit_s, path, text = rest.split(":", 2)
            limit = float(limit_s)
            t0 = time.time()
            while time.time() - t0 < limit:
                try:
                    if text in open(path, errors="replace").read():
                        break
                except OSError:
                    pass
                time.sleep(0.25)
            else:
                print(f"until: {text!r} not in {path} after {limit}s", file=sys.stderr)
        else:
            raise SystemExit(f"unknown step {step!r}")


if __name__ == "__main__":
    main()
