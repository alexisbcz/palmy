# Plays the greeter inside the e2e namespace: logs in palm/palm over the real
# palm-login socket and asks for a session that records who it runs as.
import json, os, socket, struct, sys
out = "/run/test/greeter-runs.txt"  # read back by run.sh
first = not os.path.exists("/run/test/user-session.txt")
with open(out, "a") as f:
    f.write("greeter run: uid=%d gid=%d groups=%s sock=%s palm_login=%s xdg=%s cwd=%s\n" % (
        os.getuid(), os.getgid(), sorted(os.getgroups()), os.environ.get("GREETD_SOCK"),
        os.environ.get("PALM_LOGIN"), os.environ.get("XDG_RUNTIME_DIR"), os.getcwd()))
s = socket.socket(socket.AF_UNIX); s.connect(os.environ["GREETD_SOCK"])
def ask(o):
    b = json.dumps(o).encode(); s.sendall(struct.pack("=I", len(b)) + b)
    n = struct.unpack("=I", s.recv(4))[0]; r = json.loads(s.recv(n))
    with open(out, "a") as f: f.write("  %s -> %s\n" % (o["type"], r))
    return r
if not first:
    if not os.path.exists("/run/test/powered"):
        ask({"type": "power", "action": "reboot"})
    sys.exit(0)
ask({"type": "create_session", "username": "palm"})
ask({"type": "post_auth_message_response", "response": "nope"})
ask({"type": "create_session", "username": "palm"})
ask({"type": "post_auth_message_response", "response": "palm"})
ask({"type": "start_session", "cmd": ["/bin/sh", "-c",
    "{ id; pwd; env | sort; ls -ld $XDG_RUNTIME_DIR; } > /run/test/user-session.txt; "
    "/run/test/busybox who > /run/test/who.txt 2>&1; echo to-the-log; sleep 1"],
    "env": ["XDG_SESSION_TYPE=wayland", "FROM_GREETER=yes"]})
