# Plays the wm inside the e2e namespace: run as the user session (autologin),
# it talks to palm-login's session socket the way apps/wm/login.odin does --
# a wrong unlock password, the right one, a power dry run -- waits while
# run.sh pokes the socket from outside the session, then asks for a reboot
# and exits, as the wm does after closing its windows.
#
#   python3 session-client.py            the session
#   python3 session-client.py outsider   one unlock attempt, from whoever runs it
import json, os, socket, struct, sys, time
out = "/run/test/session-client.txt" if len(sys.argv) < 2 else "/run/test/outsider-%d.txt" % os.getuid()  # read back by run.sh


def ask(o, path=None):
    s = socket.socket(socket.AF_UNIX)
    try:
        s.connect(path or os.environ.get("PALM_SESSION_SOCK", "/run/palm-login.session.sock"))
    except OSError as e:
        return {"type": "no-connect", "description": e.strerror}
    b = json.dumps(o).encode()
    s.sendall(struct.pack("=I", len(b)) + b)
    n = struct.unpack("=I", s.recv(4))[0]
    r = json.loads(s.recv(n))
    s.close()
    return r


def log(line):
    with open(out, "a") as f:
        f.write(line + "\n")


if len(sys.argv) > 1 and sys.argv[1] == "outsider":
    r = ask({"type": "unlock", "password": "palm"}, "/run/palm-login.session.sock")
    log("outsider uid=%d: %s %s" % (os.getuid(), r.get("type"), r.get("description", "")))
    sys.exit(0)

st = os.stat(os.environ["PALM_SESSION_SOCK"])
log("sock=%s uid=%d mode=%o" % (os.environ["PALM_SESSION_SOCK"], st.st_uid, st.st_mode & 0o777))
t0 = time.time()
r = ask({"type": "unlock", "password": "nope"})
log("unlock wrong: %s %s after %.1fs" % (r.get("type"), r.get("error_type", ""), time.time() - t0))
r = ask({"type": "unlock", "password": "palm"})
log("unlock right: %s" % r.get("type"))
r = ask({"type": "power", "action": "reboot", "dry_run": True})
log("power dry run: %s %s" % (r.get("type"), r.get("description", "")))
open("/run/test/session-ready", "w").close()
time.sleep(3)  # run.sh tries from outside the session now
r = ask({"type": "power", "action": "reboot"})
log("power reboot: %s %s" % (r.get("type"), r.get("description", "")))
r = ask({"type": "unlock", "password": "palm"})
log("unlock once ending: %s %s" % (r.get("type"), r.get("description", "")))
