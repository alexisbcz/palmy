# probe.py OUT ITEM...: run inside a terminal. Writes what the terminal says
# its cell size is, then for each ITEM -- a file of escape sequences, or
# "@text" with backslash escapes -- writes it to the terminal and records the
# replies and the cursor position (CPR) that follow. Then holds the screen
# for $HOLD seconds so it can be photographed.
import os, select, sys, time, tty

out = open(sys.argv[1], "w")
fd = sys.stdin.fileno()
tty.setraw(fd)


def ask(s):
    os.write(1, s.encode())
    buf = b""
    while True:
        r, _, _ = select.select([fd], [], [], 1.5)
        if not r:
            break
        buf += os.read(fd, 4096)
        if buf.endswith((b"R", b"t", b"c")):
            break
    return buf


out.write("cell %r\n" % ask("\x1b[16t"))
for item in sys.argv[2:]:
    if item.startswith("@"):
        os.write(1, item[1:].encode().decode("unicode_escape").encode("latin-1"))
    else:
        os.write(1, open(item, "rb").read())
    out.write("%s -> %r\n" % (os.path.basename(item), ask("\x1b[6n")))
out.flush()
time.sleep(float(os.environ.get("HOLD", "30")))
