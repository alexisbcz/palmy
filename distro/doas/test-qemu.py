"""doas, passwd, who and last on the real disk image, in QEMU, headless.

    python3 -I distro/doas/test-qemu.py [--image distro/out/palmy.img]

Boots a sparse copy of the image with distro/image/test-boot.py's Machine
(OVMF, limine, the serial console as a socket, QMP for screen and keys), and
on the serial console, as palm:

    the binaries are setuid root, /etc/doas.conf is root's 0644
    doas id                                   -> uid=0, after palm's password
    doas id with a wrong password             -> refused, logged
    doas palm add <pkg> over http from the host
    passwd: palm -> newpalm1                   then busybox login with it on
                                               the console, and the greeter with
                                               it on screen (wm --drm as palm)
    who / last                                 the graphical seat0 session and the
                                               console's ttyS0, and the boot record
    /var/log/messages                         doas and passwd lines (authpriv)
"""

import argparse
import importlib.util
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DISTRO = os.path.dirname(HERE)
spec = importlib.util.spec_from_file_location("testboot", os.path.join(DISTRO, "image", "test-boot.py"))
tb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tb)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default=os.path.join(DISTRO, "out", "palmy.img"))
    ap.add_argument("--work", default=os.path.join(DISTRO, "build", "doas-qemu"))
    ap.add_argument("--port", type=int, default=8093)
    ap.add_argument("--add", default="shop")
    args = ap.parse_args()
    os.makedirs(args.work, exist_ok=True)
    img = os.path.join(args.work, "test.img")
    subprocess.run(["cp", "--sparse=always", args.image, img], check=True)
    tb.serve(os.path.join(DISTRO, "out", "repo"), args.port)

    m = tb.Machine(img, args.work)
    try:
        if not m.check("getty on ttyS0", m.expect(r"palmy login: ", 90) is not None):
            return m.failures

        def login(user, pw):
            m.send(user)
            m.expect(r"Password: ", 10)
            m.send(pw)
            return m.expect(r"[$#] $", 15) is not None

        # --- as root, look at what was installed ---
        m.check("root logs in on the console", login("root", "palm"))
        m.run("stty -echo cols 200")
        out, _ = m.run("ls -ln /usr/bin/doas /usr/bin/passwd /etc/doas.conf; readlink /usr/bin/su")
        m.check("doas and passwd are setuid root", len(re.findall(r"^-rwsr-xr-x\s+\d+\s+0\s+0 ", out, re.M)) == 2, out)
        m.check("/etc/doas.conf is root's, 0644", re.search(r"^-rw-r--r--\s+\d+\s+0\s+0 .*/etc/doas.conf", out, re.M) is not None, out)
        out, _ = m.run("palm verify doas passwd palm-login; echo verify=$?")
        m.check("palm verify is clean for the new packages", "verify=0" in out, out)
        m.send("exit")

        # --- as palm on the console ---
        m.expect(r"palmy login: ", 20)
        m.check("palm logs in on the console", login("palm", "palm"))
        m.run("stty -echo cols 200")
        out, _ = m.run("id")
        m.check("palm is in wheel", "10(wheel)" in out, out)

        m.send("doas id")
        m.check("doas asks for palm's password", m.expect(r"doas \(palm@[^)]*\) password: ", 10) is not None)
        m.send("palm")
        r = m.expect(r"uid=0\(root\) gid=0\(root\)[^\n]*\n", 15)
        m.check("doas id runs as root", r is not None, m.buf[-400:])
        m.expect(r"\$ $", 5)

        m.send("doas id")
        m.expect(r"password: ", 10)
        m.send("wrong")
        m.check("a wrong password is refused", m.expect(r"doas: Authentication failed", 15) is not None, m.buf[-400:])
        m.expect(r"\$ $", 5)

        m.send(f"doas palm --repo http://10.0.2.2:{args.port}/x86_64 update && "
               f"doas palm --repo http://10.0.2.2:{args.port}/x86_64 --yes add {args.add}; echo add=$?")
        # Two doas, two passwords (the default rule has no persist).
        for _ in range(2):
            m.expect(r"password: ", 60)
            m.send("palm")
        r = m.expect(r"add=(\d+)", 180)
        m.check(f"doas palm add {args.add} installs it", r is not None and r.group(1) == "0", m.buf[-1500:])
        out, _ = m.run(f"palm info {args.add} | head -3")
        m.check(f"{args.add} is installed", "installed" in out.lower() or args.add in out, out)

        m.send("passwd")
        m.expect(r"Current password: ", 10)
        m.send("palm")
        m.expect(r"New password: ", 15)
        m.send("newpalm1")
        m.expect(r"Retype new password: ", 10)
        m.send("newpalm1")
        m.check("passwd changes palm's password", m.expect(r"passwd: password updated", 15) is not None, m.buf[-600:])
        m.expect(r"\$ $", 5)
        m.send("exit")

        # --- the new password, on the console and at the greeter ---
        m.expect(r"palmy login: ", 20)
        m.send("palm")
        m.expect(r"Password: ", 10)
        m.send("palm")
        m.check("the old password no longer logs in", m.expect(r"Login incorrect", 15) is not None, m.buf[-300:])
        m.expect(r"palmy login: ", 20)
        m.check("busybox login accepts the new one", login("palm", "newpalm1"))
        m.run("stty -echo cols 200")

        time.sleep(2)
        m.type("newpalm1\n")
        ok, out = tb.wait_for(m, "ps -o user,args | grep '[w]m --drm' || true", r"^\s*palm\s+wm --drm\s*$")
        m.check("the greeter logs palm in with the new password", ok, out)
        time.sleep(3)
        m.screen(os.path.join(args.work, "desktop.png"))

        out, _ = m.run("who")
        m.check("who: palm on seat0 (palm-login) and ttyS0 (busybox login)",
                re.search(r"^palm\s+seat0", out, re.M) is not None and re.search(r"^palm\s+ttyS0", out, re.M) is not None, out)
        out, _ = m.run("last")
        m.check("last: the sessions and the boot", re.search(r"^palm\s+seat0", out, re.M) is not None
                and re.search(r"^reboot\s+system boot", out, re.M) is not None, out)

        m.send("doas tail -n 40 /var/log/messages")
        m.expect(r"password: ", 10)
        m.send("newpalm1")
        r = m.expect(r"\$ $", 15)
        log = m.buf[-6000:]
        m.check("syslog has doas's grant", re.search(r"doas\[\d+\]: palm ran command as root from .*: id", log) is not None, log)
        m.check("syslog has doas's failure", "authentication failure for palm" in log, log)
        m.check("syslog has passwd's change", "password of palm changed by palm" in log, log)
        m.check("syslog has palm-login's session", "session opened for \"palm\"" in log, log)
    finally:
        m.close()
    return m.failures


if __name__ == "__main__":
    failures = main()
    print(f"{'all passed' if not failures else str(len(failures)) + ' failed: ' + ', '.join(failures)}")
    sys.exit(1 if failures else 0)
