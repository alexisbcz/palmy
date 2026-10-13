"""Install Palmframe onto a blank disk inside QEMU with palm-install, then boot it.

    python3 -I distro/installer/test-install.py [--keep] [--work DIR]

Everything happens inside throwaway virtual machines; on the host this
script only copies files and builds image files (no root, no loop devices,
no host block devices, no host firmware variables):

  1. A copy of distro/out/palmframe.img (the shipped system) is booted under
     OVMF with two more virtio disks: a blank 8 GiB qcow2 (the target, which
     the guest sees as /dev/vdb) and a small ext4 "tools" disk (/dev/vdc)
     carrying the palm-install just built, the host's mkfs.fat and mkfs.ext4
     with their libraries, limine's BOOTX64.EFI and the signed repository.
     The tools disk stands in for the live medium, so this test depends only
     on palm-install and the repository, not on the live ISO.
  2. As root on the serial console: palm-install --list-disks, a refusal of
     the running system's disk, a --dry-run, then the real installation to
     /dev/vdb with --yes. The new disk is mounted and its files read back.
  3. A second machine boots ONLY the target disk, under the same OVMF
     variable store, so it starts through the Boot#### entry palm-install
     wrote. On it: the host name, the user, the clock's zone, BootCurrent,
     root=PARTUUID; the greeter is screenshotted, and the new user logs in
     through it.

Screenshots and serial transcripts go to the work directory
(distro/build/installer-core/qemu by default).
"""

import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DISTRO = os.path.dirname(HERE)
OUT = os.path.join(DISTRO, "out")
OVMF_DIR = os.environ.get("OVMF_DIR", os.path.expanduser("~/.local/opt/qemu/usr/share/edk2/x64"))
if not os.path.isdir(OVMF_DIR):
    OVMF_DIR = "/usr/share/edk2/x64"
EFI_GUID = "8be4df61-93ca-11d2-aa0d-00e098032b8c"

USER = "alex"
FULL_NAME = "Alex Tester"
# Only keys that sit in the same place on QWERTY and AZERTY: the installed
# system uses the French layout chosen below, and QMP sends physical keys.
PASSWORD = "secret"
HOSTNAME = "palmtest"


class Machine:
    def __init__(self, work, name, drives, vars_fd):
        self.work = work
        self.name = name
        self.serial_path = os.path.join(work, f"{name}.serial.sock")
        self.qmp_path = os.path.join(work, f"{name}.qmp.sock")
        for p in (self.serial_path, self.qmp_path):
            if os.path.exists(p):
                os.unlink(p)
        cmd = ["qemu-system-x86_64", "-enable-kvm", "-cpu", "host", "-m", "2G", "-smp", "4",
               "-machine", "q35",
               "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_DIR}/OVMF_CODE.4m.fd",
               "-drive", f"if=pflash,format=raw,file={vars_fd}",
               "-device", "virtio-vga", "-device", "virtio-keyboard-pci", "-device", "virtio-tablet-pci",
               "-nic", "user,model=virtio-net-pci",
               "-serial", f"unix:{self.serial_path},server=on,wait=on",
               "-display", "none", "-qmp", f"unix:{self.qmp_path},server=on,wait=off",
               "-no-reboot"]
        for d in drives:
            cmd += ["-drive", d]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                     stderr=open(os.path.join(work, f"{name}.qemu.log"), "w"))
        self.serial = self._connect(self.serial_path)
        self.serial.setblocking(False)
        self.buf = ""
        self.mark = 0
        self.transcript = open(os.path.join(work, f"{name}.serial.txt"), "w")

    def _connect(self, path):
        deadline = time.time() + 15
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

    def expect(self, pattern, timeout=30, flags=re.M):
        rx = re.compile(pattern, flags)
        deadline = time.time() + timeout
        while True:
            m = rx.search(self.buf, self.mark)
            if m:
                self.mark = m.end()
                return m
            if time.time() > deadline or (not self._pump(0.1) and self.proc.poll() is not None):
                return None

    def send(self, line):
        self.serial.sendall((line + "\r").encode())

    def run(self, command, timeout=20):
        tag = f"@@{int(time.time() * 1000) % 100000}@@"
        self.send(f"echo {tag}B; {command}; echo {tag}E$?")
        m = self.expect(re.escape(tag) + r"B\n(.*?)" + re.escape(tag) + r"E(\d+)\n", timeout, re.S)
        return (m.group(1), int(m.group(2))) if m else ("(timed out)", -1)

    def login(self, user, password, prompt_host):
        if self.expect(rf"{prompt_host} login: ", 90) is None:
            return False
        time.sleep(0.5)
        self.send(user)
        if self.expect(r"Password: ", 15) is None:
            return False
        self.send(password)
        if self.expect(r"# ", 15) is None:
            return False
        self.run("stty -echo 2>/dev/null; export PS1='# '")
        return True

    def qmp(self, *commands):
        s = self._connect(self.qmp_path)
        f = s.makefile("rw")
        json.loads(f.readline())
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

    def screen(self, path):
        ppm = path + ".ppm"
        self.qmp({"execute": "screendump", "arguments": {"filename": ppm}},
                 {"execute": "screendump", "arguments": {"filename": path, "format": "png"}})
        with open(ppm, "rb") as f:
            data = f.read()
        os.unlink(ppm)
        parts = data.split(b"\n", 3)
        w, h = map(int, parts[1].split())
        return w, h, parts[3]

    def key(self, *qcodes):
        ev = lambda q, d: {"type": "key", "data": {"down": d, "key": {"type": "qcode", "data": q}}}
        self.qmp({"execute": "input-send-event", "arguments": {"events": [ev(q, True) for q in qcodes]}})
        time.sleep(0.04)
        self.qmp({"execute": "input-send-event", "arguments": {"events": [ev(q, False) for q in reversed(qcodes)]}})
        time.sleep(0.06)

    def wait_exit(self, timeout):
        try:
            self.proc.wait(timeout)
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


failures = []


def check(what, ok, detail=""):
    print(f"  {'pass' if ok else 'FAIL'}  {what}" +
          (f"\n        {detail.strip()[:2000]}" if detail and not ok else ""), flush=True)
    if not ok:
        failures.append(what)
    return ok


def colours(w, h, rgb):
    seen = set()
    for i in range(0, w * h * 3, 3 * 11):
        seen.add((rgb[i] >> 3, rgb[i + 1] >> 3, rgb[i + 2] >> 3))
        if len(seen) > 4000:
            break
    return len(seen)


def build_tools_disk(work):
    """An ext4 image with palm-install, mkfs.*, their libraries, limine, the repo."""
    stage = os.path.join(work, "tools")
    shutil.rmtree(stage, ignore_errors=True)
    for d in ("bin", "lib", "limine", "repo"):
        os.makedirs(os.path.join(stage, d))
    shutil.copy2(os.path.join(OUT, "bin", "palm-install"), os.path.join(stage, "bin", "palm-install"))
    shutil.copy2("/usr/bin/mkfs.fat", os.path.join(stage, "bin", "mkfs.fat"))
    # mke2fs picks the file system from its name, as e2fsprogs' own
    # mkfs.ext4 link does.
    shutil.copy2("/usr/bin/mke2fs", os.path.join(stage, "bin", "mkfs.ext4"))
    libs = set()
    for exe in ("/usr/bin/mke2fs", "/usr/bin/mkfs.fat"):
        out = subprocess.run(["ldd", exe], capture_output=True, text=True).stdout
        for m in re.finditer(r"=> (/\S+)", out):
            name = os.path.basename(m.group(1))
            # glibc is in the guest already, the same build as the host's.
            if not re.match(r"(libc\.so|libm\.so|ld-linux)", name):
                libs.add(m.group(1))
    for lib in libs:
        shutil.copy2(os.path.realpath(lib), os.path.join(stage, "lib", os.path.basename(lib)))
    shutil.copy2("/usr/share/limine/BOOTX64.EFI", os.path.join(stage, "limine", "BOOTX64.EFI"))
    shutil.copytree(os.path.join(OUT, "repo", "x86_64"), os.path.join(stage, "repo", "x86_64"))
    size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(stage) for f in fs)
    img = os.path.join(work, "tools.ext4")
    if os.path.exists(img):
        os.unlink(img)
    mib = size // (1 << 20) + 64
    subprocess.run(["truncate", "-s", f"{mib}M", img], check=True)
    subprocess.run(["mkfs.ext4", "-q", "-F", "-L", "tools", "-d", stage, img], check=True)
    return img, sorted(os.path.basename(l) for l in libs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", default=os.path.join(DISTRO, "build", "installer-core", "qemu"))
    ap.add_argument("--keep", action="store_true", help="keep the disks afterwards")
    args = ap.parse_args()
    work = args.work
    os.makedirs(work, exist_ok=True)
    for f in ("palmframe.img", os.path.join("bin", "palm-install"), os.path.join("repo", "x86_64", "PALMINDEX")):
        if not os.path.exists(os.path.join(OUT, f)):
            sys.exit(f"test-install: distro/out/{f} is missing")

    live = os.path.join(work, "live.img")
    target = os.path.join(work, "target.qcow2")
    vars_fd = os.path.join(work, "OVMF_VARS.fd")
    subprocess.run(["cp", "--sparse=always", os.path.join(OUT, "palmframe.img"), live], check=True)
    if os.path.exists(target):
        os.unlink(target)
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", target, "8G"], check=True)
    shutil.copy(os.path.join(OVMF_DIR, "OVMF_VARS.4m.fd"), vars_fd)
    tools, libs = build_tools_disk(work)
    print(f"test-install: work in {work}; tools disk carries {', '.join(libs)}", flush=True)

    # --- 1 + 2: install from the running system ---------------------------------
    print("machine 1: the shipped image, a blank 8 GiB disk, the tools disk", flush=True)
    m = Machine(work, "install", [f"file={live},if=virtio,format=raw",
                                  f"file={target},if=virtio,format=qcow2",
                                  f"file={tools},if=virtio,format=raw,readonly=on"], vars_fd)
    try:
        if not check("root shell on the serial console", m.login("root", "palm", "palmframe")):
            return
        out, rc = m.run("mkdir -p /tools && mount -o ro /dev/vdc /tools && "
                        "export PATH=/tools/bin:$PATH LD_LIBRARY_PATH=/tools/lib && echo ok")
        check("tools disk mounted", rc == 0 and "ok" in out, out)
        out, rc = m.run("palm-install --list-disks")
        print("    " + out.strip().replace("\n", "\n    "))
        check("--list-disks marks vda as the running system", re.search(r"/dev/vda .*running system", out) is not None, out)
        check("--list-disks shows the blank 8 GiB vdb", re.search(r"/dev/vdb\s+8\.0 GiB\s+VirtIO disk", out) is not None, out)

        m.run(f"printf '{PASSWORD}\\n' > /tmp/pw")
        common = (f"--user {USER} --full-name '{FULL_NAME}' --password-file /tmp/pw --language fr_FR "
                  f"--keyboard fr --timezone Europe/Paris --hostname {HOSTNAME} "
                  f"--repo /tools/repo/x86_64 --limine-dir /tools/limine")
        out, rc = m.run(f"palm-install --disk /dev/vda {common} --yes")
        check("installing over the running system is refused (exit 4)", rc == 4 and "running system" in out, out)
        out, rc = m.run(f"palm-install --disk /dev/vdb {common}")
        check("no --yes: refused after the summary (exit 4)", rc == 4 and "WILL BE ERASED" in out, out)
        out, rc = m.run(f"palm-install --disk /dev/vdb {common} --dry-run", 30)
        check("--dry-run succeeds", rc == 0 and "mkfs.ext4" in out, out)
        out, rc = m.run("[ -e /dev/vdb1 ] && echo partitions || echo blank")
        check("the dry run left the disk blank", "blank" in out, out)

        t0 = time.time()
        out, rc = m.run(f"palm-install --disk /dev/vdb {common} --yes", 600)
        took = time.time() - t0
        print("    " + "\n    ".join(out.strip().splitlines()[-14:]))
        if not check(f"palm-install --disk /dev/vdb --yes (exit {rc}, {took:.0f} s)", rc == 0, out + m.run("tail -40 /var/log/palm-install.log")[0]):
            return
        log, _ = m.run("cat /var/log/palm-install.log")
        with open(os.path.join(work, "palm-install.log"), "w") as f:
            f.write(log)
        check("the log has the GPT, the mkfs runs and BLKRRPART's partitions",
              "GPT written" in log and "partition nodes: /dev/vdb1 /dev/vdb2" in log and "mkfs.ext4" in log, log[-3000:])
        check("the UEFI entry was written", re.search(r"UEFI: Boot[0-9A-F]{4} \"Palmframe\"", log) is not None, log[-3000:])

        out, rc = m.run("mkdir -p /mnt/check && mount /dev/vdb2 /mnt/check && mount /dev/vdb1 /mnt/check/boot/efi && echo mounted")
        check("the new partitions mount", "mounted" in out, out)
        out, _ = m.run("cat /mnt/check/etc/hostname /mnt/check/etc/locale.conf /mnt/check/etc/palm/keyboard /mnt/check/etc/timezone; "
                       "readlink /mnt/check/etc/localtime; grep -v '^#' /mnt/check/etc/fstab; grep alex /mnt/check/etc/passwd /mnt/check/etc/group; "
                       "ls -ln /mnt/check/home; ls -l /mnt/check/etc/shadow; find /mnt/check/boot/efi -type f | sort; "
                       "grep cmdline /mnt/check/boot/efi/boot/limine/limine.conf | head -1")
        print("    " + out.strip().replace("\n", "\n    "))
        check("hostname, locale, keyboard, time zone on the new disk",
              HOSTNAME in out and "LANG=fr_FR.UTF-8" in out and "layout = fr" in out and "../usr/share/zoneinfo/Europe/Paris" in out, out)
        check("the user, in wheel/video/input/audio, home owned by uid 1000",
              "alex:x:1000:1000:Alex Tester:/home/alex:/bin/sh" in out and re.search(r"wheel:x:10:.*alex", out) is not None
              and re.search(r"drwx------\s+\d+\s+1000\s+1000 .*alex", out) is not None, out)
        check("shadow is root-only", re.search(r"-rw------- .* root .*shadow", out) is not None, out)
        check("ESP holds both limine copies, limine.conf and the kernel",
              all(p in out for p in ("/EFI/BOOT/BOOTX64.EFI", "/EFI/palmframe/BOOTX64.EFI", "/boot/limine/limine.conf", "/mnt/check/boot/efi/vmlinuz")), out)
        out, _ = m.run("palm --root /mnt/check verify 2>&1 | tail -20")
        print("    palm verify on the new disk:\n    " + out.strip().replace("\n", "\n    "))
        m.run("umount /mnt/check/boot/efi; umount /mnt/check; sync")
        m.send("poweroff")
        check("machine 1 powers off", m.wait_exit(60))
    finally:
        m.close()

    # --- 3: boot ONLY the installed disk ----------------------------------------
    print("machine 2: only the installed disk, same OVMF variables", flush=True)
    m = Machine(work, "installed", [f"file={target},if=virtio,format=qcow2"], vars_fd)
    try:
        ok = m.expect(r"palm-init", 90) is not None
        check("the installed disk boots to palm-init", ok, m.buf[-3000:])
        if not check(f"getty shows the new host name ({HOSTNAME} login:)", m.login("root", PASSWORD, HOSTNAME), m.buf[-2000:]):
            return
        check("root's password is the user's", True)
        out, _ = m.run("hostname; cat /proc/cmdline; id alex; date +%Z; ls -l /etc/localtime")
        print("    " + out.strip().replace("\n", "\n    "))
        check("root=PARTUUID on the kernel command line", "root=PARTUUID=" in out, out)
        check("alex is uid 1000 in wheel, video, input, audio",
              all(g in out for g in ("uid=1000(alex)", "wheel", "video", "input", "audio")), out)
        check("the clock is in Paris time (CET/CEST)", re.search(r"\bCES?T\b", out) is not None, out)
        out, _ = m.run(f"mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null; cd /sys/firmware/efi/efivars && "
                       f"for v in BootCurrent BootOrder; do printf '%s: ' $v; od -An -tx1 $v-{EFI_GUID}; done; "
                       f"for f in Boot0*-{EFI_GUID}; do printf '%s ' ${{f%%-*}}; od -An -c $f | tr -d ' \\n' | sed 's/\\\\0//g' | cut -c1-40; echo; done; cd /")
        print("    " + out.strip().replace("\n", "\n    "))
        cur = re.search(r"BootCurrent:\s+\S+ \S+ \S+ \S+ (\S\S) (\S\S)", out)
        order = re.search(r"BootOrder:\s+\S+ \S+ \S+ \S+ (\S\S) (\S\S)", out)
        if cur and order:
            num = f"Boot{cur.group(2).upper()}{cur.group(1).upper()}"
            check(f"booted through BootCurrent = {num}, first in BootOrder", cur.groups() == order.groups(), out)
            check(f"{num} is the Palmframe entry", re.search(rf"{num} .*Palmframe", out) is not None, out)
        else:
            check("BootCurrent/BootOrder readable", False, out)

        # The greeter, then logging in as the new user.
        greeter = False
        for _ in range(40):
            o, _ = m.run("ps | grep -c '[g]reeter'")
            if o.strip().isdigit() and int(o.strip()) > 0:
                greeter = True
                break
            time.sleep(1)
        time.sleep(4)
        shot = os.path.join(work, "installed-greeter.png")
        w, h, rgb = m.screen(shot)
        check(f"the greeter is on screen ({shot}, {w}x{h})", greeter and colours(w, h, rgb) > 20)
        for ch in PASSWORD:
            m.key(ch)
        m.key("ret")
        session = False
        for _ in range(30):
            o, _ = m.run("ps -o user,args | grep '[w]m --drm' | grep -v kiosk")
            if "alex" in o or "1000" in o:
                session = True
                break
            time.sleep(1)
        time.sleep(3)
        shot2 = os.path.join(work, "installed-desktop.png")
        m.screen(shot2)
        check(f"alex logs in through the greeter: wm --drm runs as alex ({shot2})", session,
              m.run("ps -o user,args | grep -v '\\['; tail -20 /var/log/palm-login.log")[0])
        m.send("poweroff")
        check("machine 2 powers off", m.wait_exit(60))
    finally:
        m.close()
        if not args.keep:
            for f in (live, target, tools):
                if os.path.exists(f):
                    os.unlink(f)

    print(f"test-install: {'all passed' if not failures else f'{len(failures)} failed: ' + '; '.join(failures)}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
