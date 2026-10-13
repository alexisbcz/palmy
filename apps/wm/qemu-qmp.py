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
#   until:<s>:<file>:<text>   wait up to <s> seconds until <file> contains <text>
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

    def events(self, evs):
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
            ax = x * 0x7FFF // max(size[0] - 1, 1)
            ay = y * 0x7FFF // max(size[1] - 1, 1)
            q.events([
                {"type": "abs", "data": {"axis": "x", "value": ax}},
                {"type": "abs", "data": {"axis": "y", "value": ay}},
            ])
            time.sleep(0.05)
        elif kind == "click":
            btn = rest or "left"
            q.events([{"type": "btn", "data": {"down": True, "button": btn}}])
            time.sleep(0.08)
            q.events([{"type": "btn", "data": {"down": False, "button": btn}}])
            time.sleep(0.05)
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
