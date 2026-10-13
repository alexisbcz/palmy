"""Drive a QEMU boot of palm-init over its serial console. See test-boot.sh.

The serial port is a unix socket QEMU listens on; QMP is another. Everything
the guest prints is appended to a transcript, and each step waits for a
pattern in what has arrived since the previous step, with a timeout.
"""

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time


class Abort(Exception):
    """A step the rest of the scenario depends on has failed."""


class Machine:
    def __init__(self, args, name, append, disk=None):
        self.name = name
        self.dir = args.work
        self.serial_path = os.path.join(self.dir, f"{name}.serial.sock")
        self.qmp_path = os.path.join(self.dir, f"{name}.qmp.sock")
        self.transcript_path = os.path.join(self.dir, f"{name}.transcript.txt")
        for p in (self.serial_path, self.qmp_path):
            if os.path.exists(p):
                os.unlink(p)
        cmd = [
            "qemu-system-x86_64",
            "-enable-kvm", "-cpu", "host", "-m", "1G", "-smp", "2",
            "-kernel", args.kernel,
            "-append", append,
            "-device", "virtio-vga",
            "-device", "virtio-keyboard-pci", "-device", "virtio-tablet-pci",
            "-device", "qemu-xhci,id=xhci",
            "-nic", "user,model=virtio-net-pci",
            "-display", "none", "-no-reboot",
            "-serial", f"unix:{self.serial_path},server=on,wait=on",
            "-qmp", f"unix:{self.qmp_path},server=on,wait=off",
            "-monitor", "none",
        ]
        if disk:
            cmd += ["-drive", f"file={disk},format=raw,if=virtio"]
        else:
            cmd += ["-initrd", args.initrd]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=open(os.path.join(self.dir, f"{name}.qemu.log"), "w"))
        self.serial = self._connect(self.serial_path)
        self.serial.setblocking(False)
        self.buf = ""      # everything received
        self.mark = 0      # where the next expect starts looking
        self.transcript = open(self.transcript_path, "w")
        self.failures = []

    def _connect(self, path):
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(path)
                return s
            except OSError:
                time.sleep(0.05)
        raise RuntimeError(f"cannot connect to {path}")

    def _pump(self, wait):
        end = time.time() + wait
        while True:
            try:
                data = self.serial.recv(65536)
                if not data:
                    return False
                text = data.decode("utf-8", "replace").replace("\r", "").replace("\0", "")
                self.buf += text
                self.transcript.write(text)
                self.transcript.flush()
            except BlockingIOError:
                if time.time() >= end:
                    return True
                time.sleep(0.02)
            except OSError:
                return False

    def expect(self, pattern, timeout=30, what=None, must=False):
        rx = re.compile(pattern, re.M | re.S)
        deadline = time.time() + timeout
        while True:
            m = rx.search(self.buf, self.mark)
            if m:
                self.mark = m.end()
                return m
            if time.time() > deadline or not self._pump(0.1):
                if time.time() <= deadline and self.proc.poll() is None:
                    continue
                self.fail(what or f"expected /{pattern}/ within {timeout}s")
                if must:
                    raise Abort(what or pattern)
                return None

    def send(self, line):
        self.serial.sendall((line + "\r").encode())

    def run(self, command, timeout=10):
        """Run a shell command and return its output (between our markers)."""
        tag = f"@@{int(time.time() * 1000) % 100000}@@"
        self.send(f"echo {tag}B; {command}; echo {tag}E")
        m = self.expect(r"^" + re.escape(tag) + r"B\n(.*?)^" + re.escape(tag) + r"E\n", timeout, f"command `{command}`")
        return m.group(1) if m else ""

    def check(self, what, ok, detail=""):
        print(f"  {'pass' if ok else 'FAIL'}  {what}" + (f"  ({detail})" if detail and not ok else ""))
        if not ok:
            self.failures.append(what)

    def fail(self, what):
        print(f"  FAIL  {what}")
        self.failures.append(what)

    def qmp(self, *commands):
        s = self._connect(self.qmp_path)
        f = s.makefile("rw")
        json.loads(f.readline())  # greeting
        replies = []
        for cmd in [{"execute": "qmp_capabilities"}] + list(commands):
            f.write(json.dumps(cmd) + "\n")
            f.flush()
            while True:
                r = json.loads(f.readline())
                if "event" in r:
                    continue
                replies.append(r)
                break
        s.close()
        return replies[1:]

    def wait_exit(self, timeout):
        try:
            self.proc.wait(timeout)
            self._pump(0.2)
            return True
        except subprocess.TimeoutExpired:
            return False

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        self.transcript.close()
        for p in (self.serial_path, self.qmp_path):
            if os.path.exists(p):
                os.unlink(p)


def scenario_login(args):
    print("login: getty on ttyS0, root login, device groups, hotplug, poweroff")
    m = Machine(args, "login", "console=ttyS0 rdinit=/sbin/init panic=-1 quiet")
    try:
        t0 = time.time()
        m.expect(r"palm-init: Palmframe is starting", 30, "palm-init announces itself")
        m.check("palm-init runs as PID 1", True)
        m.check("early mounts", m.expect(r"palm-init: mounted /proc /sys /dev", 10) is not None)
        m.check("hostname set", m.expect(r"palm-init: hostname palmframe", 10) is not None)
        m.check("coldplug", m.expect(r"palm-init: device permissions set on \d+ nodes", 10) is not None)
        m.check("lo up", m.expect(r"palm-init: lo up", 10) is not None)
        m.check("getty started", m.expect(r"palm-init: started getty-ttyS0", 10) is not None)
        m.expect(r"palmframe login: ", 30, "login prompt on ttyS0", must=True)
        m.check("login prompt on ttyS0", True)
        print(f"  ....  login prompt after {time.time() - t0:.1f}s")

        m.send("root")
        m.check("password prompt", m.expect(r"Password: ", 10) is not None)
        m.send("palm")
        m.expect(r"root@palmframe[^\n]*# ", 15, "root shell after login", must=True)
        m.check("root shell after login", True)

        out = m.run("id -u; hostname; readlink /proc/1/exe")
        m.check("logged in as root on palmframe, PID 1 is palm-init", out.split() == ["0", "palmframe", "/usr/bin/palm-init"], out)

        out = m.run("cut -d' ' -f2,3 /proc/mounts")
        need = ["/proc proc", "/sys sysfs", "/dev devtmpfs", "/dev/pts devpts", "/dev/shm tmpfs", "/run tmpfs", "/tmp tmpfs"]
        m.check("all early mounts present", all(n in out for n in need), out)

        out = m.run("ls -ln /dev/dri/card0 /dev/tty1 && ls -ln /dev/input/ | grep event")
        m.check("/dev/dri/card0 is root:video 0660", re.search(r"crw-rw----\s+\d+\s+0\s+39 .*card0", out) is not None, out)
        m.check("/dev/tty1 is root:tty 0620", re.search(r"crw--w----\s+\d+\s+0\s+5 .*tty1", out) is not None, out)
        m.check("/dev/input/event* are root:input 0660", re.search(r"crw-rw----\s+\d+\s+0\s+97 .*event", out) is not None, out)

        before = set(m.run("ls /dev/input | cat").split())
        r = m.qmp({"execute": "device_add", "arguments": {"driver": "usb-kbd", "id": "hotkbd", "bus": "xhci.0"}})
        m.check("QMP hot-plugs a USB keyboard", "return" in r[0], r)
        new = []
        for _ in range(30):
            time.sleep(0.2)
            new = [n for n in m.run("ls /dev/input | cat").split() if n not in before and n.startswith("event")]
            if new:
                break
        if new:
            out = m.run(f"ls -ln /dev/input/{new[0]}")
            m.check(f"hot-plugged /dev/input/{new[0]} is root:input 0660", re.search(r"crw-rw----\s+\d+\s+0\s+97 ", out) is not None, out)
        else:
            m.fail("no new event node after hotplug")

        out = m.run("ip -4 addr show eth0; cat /etc/resolv.conf", 10)
        m.check("eth0 has a DHCP address", "10.0.2.15" in out, out)

        out = m.run("ps -o pid,ppid,user,comm")
        m.check("syslogd supervised", re.search(r"syslogd", out) is not None, out)
        out = m.run("ps -o stat,comm | grep -c '^Z' || true")
        m.check("no zombies", out.strip() == "0", out)

        out = m.run("ls /var/log; head -3 /var/log/network.log")
        m.check("service logs in /var/log", "network.log" in out, out)

        # An orphan: a shell that backgrounds a child and exits at once.
        # When the child finishes it is reparented to PID 1, which must reap it.
        m.run("sh -c 'sleep 1 &'; sleep 2")
        out = m.run("ps -o stat,comm | grep -c '^Z' || true")
        m.check("orphans are reaped", out.strip() == "0", out)

        m.send("poweroff")
        m.check("shutdown announced", m.expect(r"palm-init: powering off", 15) is not None)
        m.check("root remounted read-only or reported", m.expect(r"palm-init: (/ remounted read-only|cannot remount / read-only)", 15) is not None)
        m.check("QEMU exits on poweroff", m.wait_exit(20))
    except Abort:
        pass
    finally:
        m.close()
    return m.failures


def scenario_single(args):
    failures = []
    print("single: palm.single shell, palm.autologin pass-through, reboot")
    m = Machine(args, "single", "console=ttyS0 rdinit=/sbin/init panic=-1 quiet palm.single palm.autologin=palm")
    try:
        m.check("single mode announced", m.expect(r"palm-init: palm.single: a root shell on /dev/ttyS0", 30) is not None)
        m.expect(r"root@palmframe[^\n]*# ", 20, "root shell without login", must=True)
        m.check("root shell without login", True)
        out = m.run("id -u; ls /var/log; ps -o comm | grep -c getty || true")
        m.check("no services started in single mode", out.split()[-1] == "0", out)
        out = m.run("tty; sleep 0.1 & jobs")
        m.check("the shell has a controlling tty (job control)", "/dev/ttyS0" in out and "Running" in out, out)
        m.send("reboot")
        m.check("reboot announced", m.expect(r"palm-init: rebooting", 15) is not None)
        m.check("QEMU exits on reboot (-no-reboot)", m.wait_exit(20))
    except Abort:
        pass
    finally:
        m.close()
    failures += m.failures

    print("autologin: palm.autologin reaches services as PALM_AUTOLOGIN")
    m = Machine(args, "autologin", "console=ttyS0 rdinit=/sbin/init panic=-1 quiet palm.autologin=palm")
    try:
        m.check("autologin noted", m.expect(r"palm-init: palm.autologin=palm passed to services", 30) is not None)
        m.expect(r"palmframe login: ", 30, "login prompt", must=True)
        m.send("root")
        m.expect(r"Password: ", 10)
        m.send("palm")
        m.expect(r"# ", 15, "shell", must=True)
        out = m.run("tr '\\0' '\\n' < /proc/$(pidof syslogd)/environ | grep PALM_AUTOLOGIN")
        m.check("syslogd's environment has PALM_AUTOLOGIN=palm", "PALM_AUTOLOGIN=palm" in out, out)
        # halt: the machine stops but QEMU keeps running (there is no
        # power-off), so we look for the console lines and then kill QEMU.
        m.send("kill -USR1 1")
        m.check("halt via SIGUSR1", m.expect(r"palm-init: halting", 15) is not None)
        m.check("kernel halts", m.expect(r"System halted|reboot: System halted", 15) is not None)
    except Abort:
        pass
    finally:
        m.close()
    failures += m.failures
    return failures


def scenario_disk(args):
    print("disk: ext4 root mounted ro by the kernel, remounted rw, clean after poweroff")
    m = Machine(args, "disk", "console=ttyS0 root=/dev/vda ro rootfstype=ext4 init=/sbin/init panic=-1 quiet", disk=args.disk)
    try:
        m.expect(r"palm-init: Palmframe is starting", 30, "palm-init starts from the disk", must=True)
        m.check("palm-init starts from the ext4 root", True)
        m.expect(r"palmframe login: ", 30, "login prompt", must=True)
        m.send("root")
        m.expect(r"Password: ", 10)
        m.send("palm")
        m.expect(r"root@palmframe[^\n]*# ", 15, "shell", must=True)
        out = m.run("grep ' / ' /proc/mounts; touch /written-by-test && echo writable")
        m.check("/ is ext4 and read-write", "ext4 rw" in out and "writable" in out, out)
        m.send("poweroff")
        m.check("/ remounted read-only at shutdown", m.expect(r"palm-init: / remounted read-only", 15) is not None)
        m.check("QEMU exits on poweroff", m.wait_exit(20))
    except Abort:
        pass
    finally:
        m.close()
    r = subprocess.run(["e2fsck", "-fn", args.disk], capture_output=True, text=True)
    m.check("e2fsck finds the filesystem clean", r.returncode == 0, r.stdout + r.stderr)
    r = subprocess.run(["debugfs", "-R", "stat /written-by-test", args.disk], capture_output=True, text=True)
    m.check("the file written in the guest is on disk", "Inode:" in r.stdout, r.stderr)
    return m.failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--initrd", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--disk", required=True)
    ap.add_argument("scenario", choices=["login", "single", "disk", "all"])
    args = ap.parse_args()

    failures = []
    if args.scenario in ("login", "all"):
        failures += scenario_login(args)
    if args.scenario in ("single", "all"):
        failures += scenario_single(args)
    if args.scenario in ("disk", "all"):
        failures += scenario_disk(args)
    print(f"test-boot: {'all passed' if not failures else f'{len(failures)} failed'}; transcripts in {args.work}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
