"""Boot the Palmframe kernel on emulated PC hardware and check the drivers bind.

    python3 -I distro/kernel/test-hardware.py            both scenarios
    python3 -I distro/kernel/test-hardware.py nvme       one of them
    python3 -I distro/kernel/test-hardware.py esp

Needs distro/out/palmframe.img (make -C distro image) and, for `esp`, the
signing key in distro/build/keys and an older kernel to upgrade to, given as
OLD_KERNEL=<bzImage> (default: the main checkout's, if this is a worktree).
The image is copied first, so the one that ships is never changed.

nvme   The root filesystem on an NVMe disk, booted straight from the kernel
       (-kernel/-append root=/dev/nvme0n1p2), with the PC devices a real
       machine has instead of virtio: an Intel e1000e network card, Intel HD
       Audio with a codec, an xHCI USB controller with a keyboard and a
       tablet, and an AHCI disk. Checks that palm-modules loaded the modules
       and that each driver is bound to its device, that the kernel's own
       module requests reach palm-modules (CONFIG_MODPROBE_PATH), and the
       sizes of what was installed.

esp    The kernel upgrade path: OVMF, limine, the root on virtio. The ESP is
       mounted at /boot/efi the way an installed system's fstab mounts it,
       limine.conf is pointed at boot():/vmlinuz (the path the linux package
       writes), and a linux package carrying OLD_KERNEL is installed with
       palm from a repository on a second disk. After a reboot the running
       kernel must be OLD_KERNEL: proof that `palm upgrade linux` alone
       changes what limine boots.

Serial console: busybox getty, logged in as root/palm. Transcripts in
distro/build/kernel-test/<scenario>/.
"""

import hashlib
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
WORK = os.path.join(DISTRO, "build", "kernel-test")
OVMF_DIR = os.environ.get("OVMF_DIR", os.path.expanduser("~/.local/opt/qemu/usr/share/edk2/x64"))
if not os.path.isdir(OVMF_DIR):
    OVMF_DIR = "/usr/share/edk2/x64"


class Machine:
    def __init__(self, name, args):
        self.work = os.path.join(WORK, name)
        self.sock = os.path.join(self.work, "serial.sock")
        if os.path.exists(self.sock):
            os.unlink(self.sock)
        cmd = ["qemu-system-x86_64", "-enable-kvm", "-cpu", "host", "-m", "2G", "-smp", "4",
               "-machine", "q35", "-display", "none",
               "-serial", f"unix:{self.sock},server=on,wait=on"] + args
        self.qmp_path = os.path.join(self.work, "qmp.sock")
        if os.path.exists(self.qmp_path):
            os.unlink(self.qmp_path)
        cmd += ["-qmp", f"unix:{self.qmp_path},server=on,wait=off"]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                     stderr=open(os.path.join(self.work, "qemu.log"), "a"))
        deadline = time.time() + 15
        while True:
            try:
                self.serial = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.serial.connect(self.sock)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.05)
        self.serial.setblocking(False)
        self.buf = ""
        self.mark = 0
        self.transcript = open(os.path.join(self.work, "serial.txt"), "a")

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

    def expect(self, pattern, timeout=60, flags=re.M):
        rx = re.compile(pattern, flags)
        deadline = time.time() + timeout
        while True:
            m = rx.search(self.buf, self.mark)
            if m:
                self.mark = m.end()
                return m
            if time.time() > deadline or (not self._pump(0.1) and self.proc.poll() is not None):
                return None

    def qmp(self, *commands):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(self.qmp_path)
        f = s.makefile("rw")
        json.loads(f.readline())
        replies = []
        for cmd in [{"execute": "qmp_capabilities"}] + list(commands):
            f.write(json.dumps(cmd) + "\n")
            f.flush()
            while True:
                r = json.loads(f.readline())
                if "event" not in r:
                    replies.append(r)
                    break
        s.close()
        return replies[1:]

    def send(self, line):
        self.serial.sendall((line + "\r").encode())

    def run(self, command, timeout=30):
        tag = f"@@{int(time.time() * 1000) % 100000}@@"
        self.send(f"echo {tag}B; {command}; echo {tag}E$?")
        m = self.expect(re.escape(tag) + r"B\n(.*?)" + re.escape(tag) + r"E(\d+)\n", timeout, re.S)
        return (m.group(1), int(m.group(2))) if m else ("(timed out)", -1)

    def login(self):
        if not self.expect(r"login: ", 120):
            return False
        self.send("root")
        self.expect(r"Password: ", 10)
        self.send("palm")
        return self.expect(r"# ", 20) is not None

    def wait_until(self, command, timeout=30):
        """Run command until it exits 0; its last output."""
        deadline = time.time() + timeout
        while True:
            out, rc = self.run(command)
            if rc == 0 or time.time() > deadline:
                return out, rc
            time.sleep(1)

    def stop(self):
        try:
            self.send("poweroff")
        except OSError:
            pass
        try:
            self.proc.wait(30)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()


failures = []


def check(what, ok, detail=""):
    print(f"  {'pass' if ok else 'FAIL'}  {what}" +
          (f"\n        {detail.strip()[:1500]}" if detail and not ok else ""), flush=True)
    if not ok:
        failures.append(what)
    return ok


def show(what, text):
    print(f"  ----  {what}")
    for line in text.strip().splitlines():
        print(f"        {line}")


def copy_image(name):
    src = os.path.join(OUT, "palmframe.img")
    dst = os.path.join(WORK, name, "disk.img")
    subprocess.run(["cp", "--sparse=always", src, dst], check=True)
    return dst


def scenario_nvme():
    print("nvme: root on NVMe, e1000e, HD Audio, xHCI, AHCI (direct kernel boot)")
    disk = copy_image("nvme")
    blank = os.path.join(WORK, "nvme", "ahci.img")
    subprocess.run(["truncate", "-s", "64M", blank], check=True)
    release = open(os.path.join(OUT, "kernel.release")).read().strip()
    m = Machine("nvme", [
        "-kernel", os.path.join(OUT, "bzImage"),
        "-append", "root=/dev/nvme0n1p2 rw console=ttyS0,115200 loglevel=4",
        "-drive", f"if=none,id=n,file={disk},format=raw", "-device", "nvme,drive=n,serial=palmframe",
        "-drive", f"if=none,id=a,file={blank},format=raw", "-device", "ide-hd,drive=a,bus=ide.1",
        "-device", "e1000e,netdev=net0", "-netdev", "user,id=net0",
        "-device", "intel-hda", "-device", "hda-duplex,audiodev=snd0", "-audiodev", "none,id=snd0",
        "-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-tablet",
        "-device", "pcie-root-port,id=rp5,slot=5,chassis=5", "-netdev", "user,id=net1",
        "-vga", "std",
    ])
    try:
        if not check("boots to a login prompt and root logs in", m.login(), m.buf[-3000:]):
            return
        out, _ = m.run("uname -r")
        check(f"running {release}", out.strip() == release, out)
        out, _ = m.run("echo $(mountpoint -d /) $(cat /sys/block/nvme0n1/nvme0n1p2/dev)")
        f = out.split()
        check("/ is /dev/nvme0n1p2 (built-in NVMe, no initramfs)", len(f) == 2 and f[0] == f[1], out)
        out, _ = m.run("cat /proc/sys/kernel/modprobe")
        check("the kernel's modprobe is palm-modules", out.strip() == "/usr/bin/palm-modules", out)

        # The modules service (or palm-init's coldplug hook) loads them.
        out, rc = m.wait_until("grep -q '^e1000e ' /proc/modules && grep -q '^snd_hda_intel ' /proc/modules", 40)
        check("e1000e and snd_hda_intel were loaded for their devices", rc == 0, m.run("cat /proc/modules")[0])
        drivers = {
            "e1000e": "readlink /sys/class/net/eth0/device/driver",
            "snd_hda_intel": "ls -d /sys/bus/pci/drivers/snd_hda_intel/0000:* | head -1",
            "nvme": "ls -d /sys/bus/pci/drivers/nvme/0000:* | head -1",
            "ahci": "ls -d /sys/bus/pci/drivers/ahci/0000:* | head -1",
            "xhci_hcd": "ls -d /sys/bus/pci/drivers/xhci_hcd/0000:* | head -1",
        }
        for drv, cmd in drivers.items():
            out, rc = m.run(cmd)
            check(f"{drv} is bound to its PCI device", rc == 0 and out.strip() != "" and "No such" not in out, out)
        out, rc = m.wait_until("grep -q 'HDA Intel' /proc/asound/cards && ls /dev/snd/pcmC0D0p", 20)
        check("an HDA sound card with a codec and a playback device", rc == 0, m.run("cat /proc/asound/cards; ls -l /dev/snd")[0])
        out, _ = m.run("stat -c '%G %a' /dev/snd/pcmC0D0p")
        check("/dev/snd/pcmC0D0p is root:audio 0660 (palm-init hotplug rules)", out.strip() == "audio 660", out)
        out, _ = m.run("cat /proc/bus/input/devices | grep -c 'Name=.*QEMU USB'")
        check("the USB keyboard and tablet are input devices", out.strip().isdigit() and int(out.strip()) >= 2, out)
        out, rc = m.run("ls /sys/block | tr '\\n' ' '")
        check("the AHCI disk is sda", "sda" in out, out)

        # A module the kernel asks for by alias: mounting exfat makes it call
        # /usr/bin/palm-modules -q -- fs-exfat.
        m.run("mkdir -p /mnt/x; mount -t exfat /dev/sda /mnt/x 2>/dev/null")
        out, rc = m.run("grep '^exfat ' /proc/modules")
        check("request_module(\"fs-exfat\") loaded exfat through palm-modules", rc == 0, out)
        out, rc = m.run("palm-modules load dm-crypt && grep '^dm_crypt ' /proc/modules && grep '^dm_mod ' /proc/modules")
        check("palm-modules load dm-crypt (and dm_mod, which it needs)", rc == 0, out)
        out, rc = m.run("grep -c zram /proc/swaps")
        check("zram is built in and palm-init made it swap", rc == 0, out)

        # Hotplug: a PCIe network card (igb) added to a running machine.
        r = m.qmp({"execute": "device_add", "arguments": {"driver": "igb", "bus": "rp5", "id": "hot0",
                                                         "netdev": "net1"}})
        check("QMP device_add igb", r and "error" not in r[0], str(r))
        out, rc = m.wait_until("readlink /sys/bus/pci/drivers/igb/0000:* | head -1 | grep -q . && echo bound", 30)
        check("a hotplugged igb card gets its driver", rc == 0,
              m.run("cat /proc/modules | cut -d' ' -f1 | tr '\\n' ' '; tail -3 /var/log/modules.log")[0])
        out, _ = m.run("tail -2 /var/log/modules.log")
        show("the modules service on the hotplug", out)
        # What palm-init's own hotplug handler runs: `modprobe -b -q <MODALIAS>`,
        # whichever modprobe is first in PATH.
        out, _ = m.run("command -v modprobe; ls -l $(command -v modprobe) | sed 's/.*-> //'; "
                       "modprobe -b -q fs-udf; echo modprobe-exit=$?; grep -c '^udf ' /proc/modules; "
                       "ls /usr/lib/modules/*/modules.dep.bb 2>&1 | tail -1")
        show("modprobe in PATH, asked for fs-udf", out)

        out, _ = m.run("ip -4 addr show eth0 | grep inet; cat /var/log/modules.log 2>/dev/null | head -5")
        show("eth0 and the modules service log", out)
        out, _ = m.run("wc -l < /proc/modules; du -sh /usr/lib/modules/*; ls -l /boot/vmlinuz /boot/efi/vmlinuz")
        show("modules loaded, installed sizes", out)
        out, _ = m.run("dmesg | grep -i -E 'firmware|palm-modules|error' | head -20")
        show("dmesg: firmware, errors", out)
    finally:
        m.stop()


def make_upgrade_repo(old_kernel):
    """A signed repository on an ext4 disk image holding linux-<ver>-r99 whose
    kernel is old_kernel; returns (disk image, sha256 of old_kernel)."""
    base = os.path.join(WORK, "esp")
    stage = os.path.join(base, "old-out")
    repo = os.path.join(base, "repo")
    shutil.rmtree(stage, ignore_errors=True)
    shutil.rmtree(repo, ignore_errors=True)
    os.makedirs(os.path.join(stage, "bin"))
    os.makedirs(os.path.join(repo, "x86_64"))
    shutil.copy(old_kernel, os.path.join(stage, "bzImage"))
    shutil.copy(os.path.join(OUT, "kernel.config"), os.path.join(stage, "kernel.config"))
    shutil.copy(os.path.join(OUT, "bin", "palm-modules"), os.path.join(stage, "bin", "palm-modules"))
    os.makedirs(os.path.join(stage, "modules"))
    recipe_dir = os.path.join(base, "recipe")
    shutil.rmtree(recipe_dir, ignore_errors=True)
    os.makedirs(recipe_dir)
    text = open(os.path.join(DISTRO, "recipes", "linux", "PALMBUILD")).read()
    text = re.sub(r"^pkgrel\s*=.*$", "pkgrel   = 99", text, flags=re.M)
    text = re.sub(r"^tree\s*=.*modules.*$", "dir      = /usr/lib/modules", text, flags=re.M)
    open(os.path.join(recipe_dir, "PALMBUILD"), "w").write(text)
    env = dict(os.environ, PALMFRAME_OUT=stage, PALMFRAME_ROOT=os.path.dirname(DISTRO),
               PALMFRAME_KEYS=os.path.join(DISTRO, "build", "keys"), SOURCE_DATE_EPOCH="0")
    palm = os.path.join(OUT, "bin", "palm")
    subprocess.run([palm, "build", recipe_dir, "-o", os.path.join(repo, "x86_64")], env=env, check=True,
                   stdout=subprocess.DEVNULL)
    subprocess.run([palm, "index", os.path.join(repo, "x86_64"), "--key",
                    os.path.join(DISTRO, "build", "keys", "palmframe.sec")], check=True, stdout=subprocess.DEVNULL)
    # Firmware as Arch ships it, zstd-compressed: the regulatory database
    # cfg80211 asks the firmware loader for when it starts.
    fw = os.path.join(repo, "firmware")
    os.makedirs(fw)
    for name in ("regulatory.db", "regulatory.db.p7s"):
        if os.path.isfile(f"/usr/lib/firmware/{name}"):
            subprocess.run(["zstd", "-q", "-19", f"/usr/lib/firmware/{name}", "-o", os.path.join(fw, name + ".zst")],
                           check=True)
    img = os.path.join(base, "repo.ext4")
    if os.path.exists(img):
        os.unlink(img)
    subprocess.run(["truncate", "-s", "128M", img], check=True)
    subprocess.run(["mkfs.ext4", "-q", "-F", "-d", repo, img], check=True)
    return img, hashlib.sha256(open(old_kernel, "rb").read()).hexdigest()


def scenario_esp():
    print("esp: palm installs the kernel onto the mounted ESP, limine boots it")
    old = os.environ.get("OLD_KERNEL")
    if not old:
        main = os.path.join(DISTRO.split("/.claude/worktrees/")[0], "distro", "out", "bzImage")
        old = main if os.path.isfile(main) and os.path.realpath(main) != os.path.join(OUT, "bzImage") else ""
    if not old or not os.path.isfile(old):
        check("an OLD_KERNEL to upgrade to", False, "set OLD_KERNEL=<bzImage>")
        return
    disk = copy_image("esp")
    repo_img, old_sum = make_upgrade_repo(old)
    vars_fd = os.path.join(WORK, "esp", "OVMF_VARS.fd")
    shutil.copy(os.path.join(OVMF_DIR, "OVMF_VARS.4m.fd"), vars_fd)
    args = [
        "-drive", f"if=pflash,format=raw,readonly=on,file={os.path.join(OVMF_DIR, 'OVMF_CODE.4m.fd')}",
        "-drive", f"if=pflash,format=raw,file={vars_fd}",
        "-drive", f"file={disk},if=virtio,format=raw",
        "-drive", f"file={repo_img},if=virtio,format=raw",
        "-device", "virtio-vga", "-nic", "user,model=virtio-net-pci",
    ]
    m = Machine("esp", args)
    try:
        if not check("first boot (OVMF, limine, new kernel) reaches a login", m.login(), m.buf[-3000:]):
            return
        out, _ = m.run("zcat /proc/config.gz | grep '^CONFIG_MODULES='")
        check("running the new kernel (CONFIG_MODULES=y)", "CONFIG_MODULES=y" in out, out)
        out, rc = m.run("(mountpoint -q /boot/efi || mount -t vfat -o rw,relatime,fmask=0077,dmask=0077 /dev/vda1 /boot/efi) && "
                        "sed -i 's|boot():/boot/vmlinuz|boot():/vmlinuz|' /boot/efi/boot/limine/limine.conf && "
                        "grep -c 'boot():/vmlinuz' /boot/efi/boot/limine/limine.conf")
        show("the ESP mount", m.run("grep /boot/efi /proc/mounts")[0])
        check("ESP mounted at /boot/efi, limine.conf points at boot():/vmlinuz", rc == 0, out)
        out, rc = m.run("mkdir -p /mnt/repo && mount -o ro /dev/vdb /mnt/repo && "
                        "rm -f /usr/lib/firmware/regulatory.db*; rmmod cfg80211 2>/dev/null; dmesg -c >/dev/null; "
                        "palm-modules load cfg80211 && sleep 2 && dmesg -c | grep -i -E 'regulatory|cfg80211'")
        check("without the file, cfg80211 says it cannot load regulatory.db (the control)",
              "failed to load regulatory.db" in out, out)
        out, rc = m.run("mkdir -p /usr/lib/firmware && cp /mnt/repo/firmware/* /usr/lib/firmware/ && "
                        "rmmod cfg80211 && palm-modules load cfg80211 && sleep 2 && dmesg -c | grep -i -E 'regulatory|cfg80211'")
        check("with regulatory.db.zst it loads: the kernel's firmware loader reads zstd",
              rc == 0 and "failed to load regulatory.db" not in out and "loading compiled-in x.509" in out.lower(), out)
        show("dmesg after loading cfg80211 with the firmware", out)
        m.run("rm -f /usr/lib/firmware/regulatory.db*")
        out, rc = m.run("palm --repo /mnt/repo/x86_64 --yes upgrade linux 2>&1 | tail -5", 120)
        check("palm installs linux r99 from the repository disk", rc == 0, out)
        out, _ = m.run("sha256sum /boot/efi/vmlinuz /boot/vmlinuz")
        check("/boot/efi/vmlinuz on the ESP is the package's kernel", out.count(old_sum) == 2, out + "\nwant " + old_sum)
        out, rc = m.run("palm verify linux 2>&1 | tail -5")
        check("palm verify linux is clean on the vfat ESP", rc == 0, out)
        m.run("umount /mnt/repo; sync")
        m.send("reboot")
        if not check("second boot reaches a login", m.login(), m.buf[-3000:]):
            return
        out, _ = m.run("zcat /proc/config.gz | grep -E '^(# )?CONFIG_MODULES[= ]'")
        check("running OLD_KERNEL from the ESP now (CONFIG_MODULES not set)", "CONFIG_MODULES is not set" in out, out)
        # vfat keeps no modes: after a remount every file is 0777 & ~fmask.
        out, rc = m.run("palm verify linux 2>&1 | tail -5")
        check("palm verify linux is still clean after the ESP was remounted", rc == 0, out)
    finally:
        m.stop()


def main():
    names = sys.argv[1:] or ["nvme", "esp"]
    if not os.path.isfile(os.path.join(OUT, "palmframe.img")):
        sys.exit("test-hardware: distro/out/palmframe.img is missing (make -C distro image)")
    for n in names:
        os.makedirs(os.path.join(WORK, n), exist_ok=True)
        {"nvme": scenario_nvme, "esp": scenario_esp}[n]()
    print(f"{len(failures)} failure(s)" if failures else "all passed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
