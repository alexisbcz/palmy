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
        m.check("early hooks run", m.expect(r"palm-init: early hook 20-order done", 10) is not None)
        m.check("coldplug", m.expect(r"palm-init: device permissions set on \d+ nodes", 10) is not None)
        m.check("hostname set", m.expect(r"palm-init: hostname palmframe", 10) is not None)
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

        out = m.run("cat /run/early")
        m.check("early hooks: /etc replaced /usr/lib's 10-mark, then 20-order", out.split("\n")[:2] == ["etc-10", "20 early services=0"], out)
        m.check("early hooks ran before any service", "services=0" in out, out)

        out = m.run("cat /proc/swaps; ls /sys/block | grep -c zram || true")
        if out.strip().endswith("0"):
            m.check("no zram in this kernel: said so, no swap", "zram: this kernel has no zram" in m.buf, out)
        else:
            m.check("zram swap is on, priority 100", re.search(r"/dev/zram0\s+partition\s+\d+\s+\d+\s+100", out) is not None, out)
        out = m.run("cat /etc/machine-id")
        m.check("/etc/machine-id written (32 hex digits)", re.fullmatch(r"[0-9a-f]{32}\n", out) is not None, out)

        # SIGHUP: a new service starts, a changed one restarts with its new
        # definition, a removed one stops.
        def sleepers():
            return m.run("ps -o args | grep '^/bin/sleep 10[0-9][0-9]' | sed 's|^/bin/||' | sort || true").split("\n")
        m.run("printf 'cmd = /bin/sleep 1001\\n' > /etc/palm/services/huptest; kill -HUP 1")
        m.check("SIGHUP: one new service", m.expect(r"palm-init: SIGHUP: 1 new, 0 changed, 0 removed", 5) is not None)
        time.sleep(0.5)
        m.check("SIGHUP: the new service runs", "sleep 1001" in sleepers(), sleepers())
        m.run("printf '# a comment\\ncmd  =  /bin/sleep  1001\\n' > /etc/palm/services/huptest; kill -HUP 1")
        m.check("SIGHUP: a comment is not a change", m.expect(r"palm-init: SIGHUP: 0 new, 0 changed, 0 removed", 5) is not None)
        m.run("printf 'cmd = /bin/sleep 1002\\n' > /etc/palm/services/huptest; kill -HUP 1")
        m.check("SIGHUP: a changed service is restarted", m.expect(r"palm-init: huptest stopped; starting it with its new definition", 8) is not None)
        time.sleep(0.5)
        s = sleepers()
        m.check("SIGHUP: the new definition runs, the old one is gone", "sleep 1002" in s and "sleep 1001" not in s, s)
        m.run("printf 'cmdd = /bin/sleep 1003\\n' > /etc/palm/services/huptest; kill -HUP 1")
        m.check("SIGHUP: a broken file keeps the running service", m.expect(r"palm-init: service huptest: line 1: unknown key \"cmdd\" — kept as it was", 5) is not None)
        m.run("rm /etc/palm/services/huptest; kill -HUP 1")
        m.check("SIGHUP: a removed service is stopped", m.expect(r"palm-init: huptest stopped and removed", 8) is not None)
        time.sleep(0.3)
        s = sleepers()
        m.check("SIGHUP: nothing of it is left", not any("sleep 10" in x for x in s), s)
        m.run("printf 'cmd = /bin/sleep 1004\\n' > /etc/palm/services/huptest2; kill -HUP 1; sleep 0.5; touch /etc/palm/services.off/huptest2 2>/dev/null || { mkdir -p /etc/palm/services.off && touch /etc/palm/services.off/huptest2; }; kill -HUP 1")
        m.check("SIGHUP: masking a running service stops it", m.expect(r"palm-init: huptest2 stopped and removed", 8) is not None)
        m.run("rm -f /etc/palm/services/huptest2 /etc/palm/services.off/huptest2")
        out = m.run("ps -o args | grep -c '^/sbin/syslogd' || true")
        m.check("SIGHUP: unchanged services were left running", out.strip() == "1", out)

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


def gpt_of(disk):
    """sfdisk's view of the disk: (last LBA of partition 2, disk sectors, verify output)."""
    r = subprocess.run(["sfdisk", "--json", disk], capture_output=True, text=True)
    table = json.loads(r.stdout)["partitiontable"] if r.returncode == 0 else {}
    parts = table.get("partitions", [])
    end = parts[1]["start"] + parts[1]["size"] - 1 if len(parts) > 1 else -1
    v = subprocess.run(["sfdisk", "--verify", disk], capture_output=True, text=True)
    return end, os.path.getsize(disk) // 512, (v.stdout + v.stderr).strip(), table.get("lastlba", -1)


def root_fsck(disk, work):
    """e2fsck -fn on partition 2, copied out of the disk image."""
    r = subprocess.run(["sfdisk", "--json", disk], capture_output=True, text=True)
    p = json.loads(r.stdout)["partitiontable"]["partitions"][1]
    part = os.path.join(work, "grow.root.ext4")
    subprocess.run(["dd", f"if={disk}", f"of={part}", "bs=512", f"skip={p['start']}", f"count={p['size']}",
                    "conv=sparse", "status=none"], check=True)
    r = subprocess.run(["e2fsck", "-fn", part], capture_output=True, text=True)
    d = subprocess.run(["dumpe2fs", "-h", part], capture_output=True, text=True)
    os.unlink(part)
    m = re.search(r"Block count:\s+(\d+).*?Block size:\s+(\d+)", d.stdout, re.S)
    size = int(m.group(1)) * int(m.group(2)) if m else 0
    return r.returncode, r.stdout + r.stderr, size, p["size"] * 512


def login_root(m):
    m.expect(r"palmframe login: ", 40, "login prompt", must=True)
    m.send("root")
    m.expect(r"Password: ", 10)
    m.send("palm")
    m.expect(r"root@palmframe[^\n]*# ", 15, "shell", must=True)


def scenario_grow(args):
    print("grow: GPT disk enlarged after it was built; grow-root, ESP, swap, fsck policy, clean shutdown")
    failures = []
    disk = args.grow_disk
    end0, sectors, _, _ = gpt_of(disk)
    print(f"  ....  before boot: root ends at sector {end0}, disk has {sectors} sectors")
    append = "console=ttyS0 root=/dev/vda2 ro rootfstype=ext4 init=/sbin/init panic=-1 quiet"
    m = Machine(args, "grow", append, disk=disk)
    machine_id = ""
    try:
        m.expect(r"palm-init: Palmframe is starting", 30, "palm-init starts", must=True)
        m.check("fsck of / is attempted (no fsck.ext4 in this busybox: said so)", m.expect(r"palm-init: fsck /: no fsck.ext4; not checked", 10) is not None)
        m.check("grow-root: the partition is extended", m.expect(r"palm-init: grow-root: vda2 now ends at 1023 MiB \(was 159 MiB\)", 10) is not None)
        m.check("grow-root: ext4 grown online", m.expect(r"palm-init: grow-root: / grown from 128 MiB to 992 MiB", 15) is not None)
        m.check("fstab: the ESP mounted by label", m.expect(r"palm-init: mounted /dev/vda1 on /boot/efi \(vfat\)", 10) is not None)
        login_root(m)
        out = m.run("df -m / | tail -1; cat /proc/swaps; grep -E ' /(boot/efi)? ' /proc/mounts; ls /etc/palm/grow-root 2>&1; cat /etc/machine-id")
        print("        " + out.strip().replace("\n", "\n        "))
        df = re.search(r"^/dev/(?:root|vda2)\s+(\d+)\s+\d+\s+\d+", out, re.M)
        m.check("df: / is about 1 GiB now", df is not None and int(df.group(1)) > 900, out)
        m.check("/ is mounted rw with fstab's relatime", re.search(r"^/dev/(?:root|vda2) / ext4 rw,relatime", out, re.M) is not None, out)
        m.check("/boot/efi is vfat with fmask/dmask 0077 and utf8", re.search(r"/dev/vda1 /boot/efi vfat rw,relatime,fmask=0077,dmask=0077.*utf8", out) is not None, out)
        m.check("/etc/palm/grow-root is gone", "No such file" in out, out)
        mid = re.search(r"^([0-9a-f]{32})$", out, re.M)
        machine_id = mid.group(1) if mid else ""
        m.check("a machine id was made", machine_id != "", out)
        # A swap file, the way a person adds one, for the second boot.
        out = m.run("dd if=/dev/zero of=/swapfile bs=1M count=16 2>/dev/null && chmod 600 /swapfile && mkswap /swapfile >/dev/null && "
                    "printf '/swapfile\\tnone\\tswap\\tsw,pri=5\\t0 0\\n' >> /etc/fstab && echo made", 20)
        m.check("a swap file made in the guest", "made" in out, out)
        m.send("poweroff")
        m.check("shutdown: /boot/efi unmounted", m.expect(r"palm-init: unmounted /boot/efi", 10) is not None)
        m.check("shutdown: / read-only", m.expect(r"palm-init: / remounted read-only", 10) is not None)
        m.check("QEMU exits on poweroff", m.wait_exit(20))
    except Abort:
        pass
    finally:
        m.close()
    failures += m.failures

    end1, sectors, verify, lastlba = gpt_of(disk)
    def check(what, cond, detail=""):
        print(f"  {'pass' if cond else 'FAIL'}  {what}" + (f"  ({detail})" if detail and not cond else ""))
        if not cond:
            failures.append(what)
    check("host: sfdisk --verify finds the GPT clean (backup at the end)", "No errors detected" in verify and lastlba == sectors - 34, verify)
    check("host: partition 2 ends on the last whole MiB", (end1 + 1) % 2048 == 0 and sectors - 34 - end1 <= 2048, f"{end1} of {sectors}")
    rc, text, fs, part = root_fsck(disk, args.work)
    check("host: e2fsck -fn finds the grown filesystem clean", rc == 0, text)
    check("host: the filesystem fills the partition", 0 <= part - fs < 1 << 20, f"fs {fs} part {part}")

    print("grow (second boot): nothing left to grow, same machine id")
    m = Machine(args, "grow2", append, disk=disk)
    try:
        m.check("fstab: the swap file is on", m.expect(r"palm-init: swap on /swapfile", 30) is not None)
        login_root(m)
        m.check("no grow-root on the second boot", "grow-root" not in m.buf, m.buf[-2000:])
        out = m.run("cat /etc/machine-id; cat /proc/swaps")
        m.check("the machine id survived the reboot", machine_id != "" and out.split("\n")[0] == machine_id, out)
        m.check("/swapfile is in /proc/swaps with priority 5", re.search(r"^/swapfile\s+file\s+\d+\s+\d+\s+5$", out, re.M) is not None, out)
        if "/dev/zram0" in out:
            m.check("zram beside the swap file, higher priority", re.search(r"/dev/zram0\s+partition\s+\d+\s+\d+\s+100", out) is not None, out)
        m.send("poweroff")
        m.check("shutdown: swap off", m.expect(r"palm-init: swap off /swapfile", 15) is not None)
        m.check("QEMU exits on poweroff", m.wait_exit(20))
    except Abort:
        pass
    finally:
        m.close()
    failures += m.failures
    return failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--initrd", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--disk", required=True)
    ap.add_argument("--grow-disk", required=True)
    ap.add_argument("scenario", choices=["login", "single", "disk", "grow", "all"])
    args = ap.parse_args()

    failures = []
    if args.scenario in ("login", "all"):
        failures += scenario_login(args)
    if args.scenario in ("single", "all"):
        failures += scenario_single(args)
    if args.scenario in ("disk", "all"):
        failures += scenario_disk(args)
    if args.scenario in ("grow", "all"):
        failures += scenario_grow(args)
    print(f"test-boot: {'all passed' if not failures else f'{len(failures)} failed'}; transcripts in {args.work}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
